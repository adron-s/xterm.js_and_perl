#!/usr/bin/perl
use POSIX qw(setsid);
use Data::Dumper;
use Time::Piece;
use Time::HiRes;
use AnyEvent::Socket;
use AnyEvent::Handle;
use AnyEvent::Util;
use Protocol::WebSocket::Handshake::Server;
use Protocol::WebSocket::Frame;
use MIME::Base64;
use IO::Pty ();
use Encode qw(encode decode FB_PERLQQ);
use utf8;
use strict;
use warnings;

#binmode(STDIN, ":utf8");
#binmode(STDOUT, ":utf8");

my $msg_count = 0;
my $bind_ip = "127.0.0.1";

my $client_counter = 0;
my %clients;

#подготавливает и запускает указанную команду при
#этом подключая ее I/O к переданному $pty
sub spawn(){
	my ($pty, @cmd) = @_;
  my ($pid, $tty, $tty_fd);
  #форкаемся чтобы выполнить программу в процессе-потомке
  unless($pid = fork){#мы потомок
  	die "problem spawning program: $!\n" unless defined $pid;
    #отсоединяем процесс от его управляющего терминала
		#а так же становимся лидером новой группы процессов
    setsid() or die "setsid failed: $!";
    #подсоединяем процесс к новому управляющему
		#терминалу(нереданному нам pseudo tty)
    $pty->make_slave_controlling_terminal;
    $tty = $pty->slave;
    $tty_fd = $tty->fileno;
    close $pty;
    #перенаплавряем стандартный ввод/вывод в новый управляющий терминал
    open STDIN, "<&$tty_fd" or die $!;
    open STDOUT, ">&$tty_fd" or die $!;
    open STDERR, ">&STDOUT" or die $!;
    close $tty;
    #запускаем запрошенную программу
    exec @cmd or die "problem executing $cmd[0]\n";
  }#конецц дочернего процесса
	return $pid;
}

#устанавливает размер(число строк и столбцов) терминала
#в новой версии(1.12) IO::Pty есть эта ф-я но в той что у меня(1.08) ее нет!
sub set_winsize(){
	my ($tty, $cols, $rows) = @_;
	my $winsize = pack('SSSS', $rows, $cols, 0, 0);  # rows, cols, pixelsX, pixelsY
  ioctl($tty, &IO::Tty::Constant::TIOCSWINSZ, $winsize);
}

#реализация JavaScript escape
sub js_escape() {
	my $string = shift;
	$string =~ s{([\x00-\x29\x2C\x3A-\x40\x5B-\x5E\x60\x7B-\x7F])}
							{'%' . uc(unpack('H2', $1))}eg; # XXX JavaScript compatible
	$string = encode('ascii', $string, sub { sprintf '%%u%04X', $_[0] });
	return $string;
}

#реализация JavaScript unescape
sub js_unescape() {
	my $escaped = shift;
	$escaped =~ s/%u([0-9a-f]{4})/chr(hex($1))/eig;
	$escaped =~ s/%([0-9a-f]{2})/chr(hex($1))/eig;
	return $escaped;
}

#проверяет что закодированое в первом utf8 байте($fb) кол-во байт == $noc
#noc - необходимое кол-во utf8 байт(1..6)
#более подробно смотри табличку https://ru.wikipedia.org/wiki/UTF-8
sub check_utf8_first_byte(){
	my($fb, $noc) = @_;
	if($noc <= 1){
		return 1 unless($fb >> 7); #good
		return 0; #bad
	}
	return 0 if($noc > 6);
	my $c = 0;
	while($fb & 0x80){
		$c++;
		#printf("!%d -- %08b\n", $c, $fb);
		$fb = ($fb << 1) & 0xFF;
	}
	return $c == ($noc);
}

sub buffer_4095_bytes_split_protect_and_fix($$){
	my($chunk, my $ogr) = @_;
	if(defined(${$ogr})){ #если остался огрызок с предидущего прохода
		#print Dumper(unpack("C*", ${$ogr})) . "\n";
		${$chunk} = ${$ogr} . ${$chunk};
		${$ogr} = undef;
		printf("with org size = %d\n\n", length(${$chunk}));
	}
	my $noc = 1;
	my @p = unpack("C*", ${$chunk});
	#т.к. в utf8 коде один символ не может занимать от 1 до
	for(my $a = $#p; ($a >= 0) && ($a > $#p - 6); $a--){ #максимум 6 байт
		my $fb = $p[$a];
		#если текущий байт это 2..6 байт UTF8
		if(($fb & 0xC0) == 0x80){ #маска 10xxxxxx
			$noc++; #считаем сколько таких "не первых"
			next; #байт нам встретилось
		}
		#если мы тут => нашли "первый байт" utf8 символа
		#проверим все ли его 2..6 байты были найдены в текущей чанке
		unless(&check_utf8_first_byte($fb, $noc)){
			#не все. часть его байтов отсутствует и будет получена только в
			#следующей чанке. так что сохраним байты этого utf8 символа в ogr.
			${$ogr} = pack("C", pop @p);
			${$ogr} = pack("C", pop @p) . ${$ogr} for 2..$noc;
			${$chunk} = pack("C*", @p); #перепаковываем эту чанку(уже без $ogr байт)
			printf("noc = $noc. fb = 0x%x\n", $fb);
			printf("ogr size = %d\n", length(${$ogr}));
			printf("new size = %d\n", length(${$chunk}));
		}
		last;
	}
}

sub create_and_cook_pty($$){
	my($ws_hdl, $ws_frame) = @_;
	my $pty = undef;
	my $ogr = undef; #огрызок от юникода. используется для борьбы против 4095 байтового буферного предела.
	&debug("Creating pty\n");
  $pty = new IO::Pty or die "Can't create try: $?\n";
	&debug("mking hdl for pty\n");
	my $hdl = new AnyEvent::Handle(fh => $pty,
		on_read => sub {
			my($hdl) = @_;
			my $chunk = $hdl->{rbuf};
			$hdl->{rbuf} = undef;
			#print Dumper(unpack("C*", $chunk)) . "\n";
			#printf("buf size = %d\n", length($chunk));
			&buffer_4095_bytes_split_protect_and_fix(\$chunk, \$ogr);
			#printf("chunk2 size = %d\n", length($chunk2));
			#если последний параметр == 1 то будет умирать при ошибке декодирования буфера!
			#если же 0 то просто будет вставлять '?' символ в экран результата
			my $str = decode('UTF-8', $chunk, 0); #1 удобен для отладки
			$str = &js_escape($str); #перепаковываем в %04X формат
			#print Dumper($str) ."\n";
			$str = encode_base64($str); #кодируем полученную строку в base64
			#print "send str = '$str'\n";
			$ws_hdl->push_write($ws_frame->new($str)->to_bytes); #передаем браузеру
		}
	);
	return ( $hdl, $pty );
}

my $cv = AnyEvent->condvar;

#обработчик сигнала когда нас убивать будут
$SIG{INT} = $SIG{TERM} = sub(){
	$cv->send(); #пнем AnyEvent
};

AnyEvent::Socket::tcp_server $bind_ip, 8195, sub {
	my ($clsock, $host, $port) = @_;
	my $hs    = Protocol::WebSocket::Handshake::Server->new;
	my $frame = Protocol::WebSocket::Frame->new;

	#вызывается при присоединении клиента
	&debug("Connection from $host:$port\n");
	#http://search.cpan.org/~mlehmann/AnyEvent-7.14/lib/AnyEvent/Handle.pm
	#это просто обработчик tcp сокетов(read/write/eof/error). он ничего не знает про webSockets!
	my $hdl = new AnyEvent::Handle(fh => $clsock);
	my $pty_hdl, my $pty, my $pid;
	my $client_id = ++$client_counter;
	my $shutdown = 0;
	my $do_shutdown;
	$clients{$client_id} = {
		'id' => $client_id,
		shutdown => sub(){
			#этот callback будет вызываться извне уже при завершении master процесса
			&$do_shutdown();
		}
	};
	$hdl->on_read(sub { #просто читалка данных с сокета
			return if $shutdown;
		my $chunk = $hdl->{rbuf};
		$hdl->{rbuf} = undef;
		#&debug("reading data: %d bytes\n", length($chunk));
		if(!$hs->is_done){ #handshake веб сокет протокола. делается один раз в самом начале.
			&debug("Invoke WebSocket handshake\n");
			$hs->parse($chunk);
			if($hs->is_done){ #проверяем что все внутренности веб сокет протокола обработали
				&debug("WebSocket handshake is done\n");
				$hdl->push_write($hs->to_string); #шлем ответ
				#создаем $pty для этого соединения
				($pty_hdl, $pty) = &create_and_cook_pty($hdl, $frame);
				return;
			}
			#handshake так и не бьл выполнен. закрываем это соединение.
			&debug("WebSocket handshake is FAULT !!!\n");
			&$do_shutdown();
			return;
		}
		#данные передаются фреймами. парсим содержимое буфера. там может быть пачка фреймов!
		#http://search.cpan.org/~vti/Protocol-WebSocket-0.21/lib/Protocol/WebSocket/Frame.pm
		$frame->append($chunk);
		#а тут уже читаем все фреймы и сообщения в них
		while($shutdown == 0){
			#выгребаем буфер данных фрейма и переходим с следующему
			#это буфер данных! не строка! для получения текстового
			#сообщения нужно еще сделать Decode(смотрни Frame.pm)
			my $buf = $frame->next_bytes;
			last unless defined($buf); #если больше фреймов в цепочке нет => прерываем while
			if($frame->is_close()){
				&debug("Received CLOSE request frame from client!\n");
				&$do_shutdown();
				last;
			}
			#&debug("frame opcode = %d\n", $frame->opcode);
			#декодим полученный буфер
			my $str = decode('UTF-8', $buf);
			#print "recv ccc = '$str'\n";
			if(index($str, "cr:") == 0){
					#получаем размеры xterm.js терминала(его cols/rows зависят
					#от заданных для бокса контейнера width/height)
					my(undef, $cols, $rows) = split(':', $str);
					&debug("Setup pty window size: $cols x $rows\n");
					&set_winsize($pty, $cols, $rows);
					$pid = &spawn($pty, "bash"); #запуск целевой задачи
			}else{
				$str = decode_base64($str);
				$str = &js_unescape($str);
				#print Dumper($str) ."\n";
				$str = encode('UTF-8', $str);
				$pty_hdl->push_write($str);
			}
			#$frame->is_binary() || next; #дальше работаем только с бинарными фреймами
			#&debug("Send ansver!\n");
			#$hdl->push_write($frame->new('hello')->to_bytes);
		}
	});

	$hdl->on_eof(sub {
		&debug("EoF!\n");
		&$do_shutdown();
	});

	$hdl->on_error(sub {
		&debug("ErrOR!\n");
		&$do_shutdown();
	});
	$do_shutdown = sub {
		&debug("Shutdowning connection $host:$port\n");
		$shutdown = 1;
		#прерваем выполнение целевой программы
		print "killing pid = $pid\n";
		kill SIGINT => (-1 * $pid) if defined($pid);
		undef $pid if defined($pid);
		undef $pty_hdl if defined $pty_hdl;
		close $pty if defined($pty);
		$hdl->destroy();
		&debug("Shutdown $host:$port done\n");
	};
};

#запуск основного цикла
$cv->wait;

#основной цикл AnyEvent завершился. закрываем открытые соединения/запущенные в них процессы
for my $c (values %clients){
	&debug("Send shutdown to client with id := '$c->{id}'\n");
	&{$c->{shutdown}}();
}

#***************************************************
#отладка
sub debug(){
	#раскоменти нижнюю строку для включения отладки
	printf @_;
}#--------------------------------------------------

