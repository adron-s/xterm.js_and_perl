function printd(){
	console.log.apply(this, arguments);
}

function x2(){
	var url = "ws://127.0.0.1:8195";
	terminalContainer = document.getElementById('terminal-container');

  xterm = new Terminal();
	xterm.open(terminalContainer, true);
	xterm.fit();
	cc = new WebSocket(url);
	//вызовется, когда соединение будет установлено
	cc.onopen = function(){
		printd("WS connection is opened");
		xterm._initialized = true;
	  var initialGeometry = xterm.proposeGeometry();
    var cols = initialGeometry.cols;
    var rows = initialGeometry.rows;
		cc.send("cr:" + cols + ":" + rows);
	  charWidth = Math.ceil(xterm.element.offsetWidth / cols);
   	charHeight = Math.ceil(xterm.element.offsetHeight / rows);
		console.log(cols, rows, charWidth, charHeight);
	};
	//когда соединено закроется
	cc.onclose = function(e){
		printd("WS connection is closed");
	};
	//каждый раз, когда браузер получает какие-то данные через веб-сокет
	cc.onmessage = function(e){
		var mess = unescape(atob(e.data));
		xterm.write(mess);
		//printd("WS message:", mess);
	};
	cc.onerror = function(e){
		console.warn("colcom wss error!");
	};

  xterm.on('data', function(data){
		cc.send(btoa(escape(data)));
	});
}
