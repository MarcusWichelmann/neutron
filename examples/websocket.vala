/*
 * This file is part of the neutron project.
 * 
 * Copyright 2013 Richard Wiedenhöft <richard.wiedenhoeft@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
using Neutron;

int main(string[] argv) {
	var tcontrol = new ThreadController(4);
	tcontrol.push_default();

	var http = new Http.Server();
	http.select_entity.connect(on_select_entity);
	http.port = 8080;

	new MainLoop().run();
	return 0;
}

void on_select_entity(Http.Request request, Http.EntitySelectContainer container) {
	switch(request.path) {
	case "/":
		string protocol = null;
		protocol = "ws";

		container.set_entity(new Http.StaticEntity("text/html", """
<!DOCTYPE html>
<html>
<head>
        <meta charset="utf-8" />
        <script src="https://code.jquery.com/jquery-2.0.3.min.js"></script>
        <style>
                .connected {
                        visibility: hidden;
                }
                .disconnected {
                        visibility: visible;
                }
        </style>
        <script>
                var socket;
                function ws_connect() {
                        socket = new WebSocket("%s://%s/socket");
                        socket.onopen = function() {
                                $(".disconnected").css("visibility", "hidden");
                                $(".connected").css("visibility", "visible");
                        }
                        socket.onclose = function() {
                                $(".disconnected").css("visibility", "visible");
                                $(".connected").css("visibility", "hidden");
                        }
                        socket.onerror = function() {
                                alert("ERROR!!!");
                                socket.close();
                        }
                        socket.onmessage = function(msg) {
                                alert(msg.data);
                        }
                }

                function ws_send() {
                        socket.send($("#input").val());
                }

                function ws_disconnect() {
                        socket.close();
                }
        </script>
</head>
<body>
        <h1>WS Test</h1>
        <button type="button" class="disconnected" onclick="ws_connect()">Connect</button><br />
        <button type="button" class="connected" onclick="ws_disconnect()">Disconnect</button><br />
        <input type="text" id="input" class="connected"><button type="button" class="connected" onclick="ws_send()">Send</button><br />
</body>
</html>
""".printf(protocol, request.get_header_var("host"))));
		break;
	case "/socket":
		var entity = new Websocket.HttpUpgradeEntity();
		entity.incoming.connect(on_incoming_ws);
		container.set_entity(entity);
		break;
	}
}

void on_incoming_ws(Websocket.Connection conn) {
	conn.ref();

	conn.on_message.connect(on_message);
	conn.on_error.connect(on_error);
	conn.on_close.connect(on_close);
	conn.start();
}

void on_message(string message, Websocket.Connection conn) {
	conn.send.begin("Got line: %s".printf(message));
}

void on_error(string msg, Websocket.Connection conn) {
	message(msg);
}

void on_close(Websocket.Connection conn) {
	conn.unref();
}
