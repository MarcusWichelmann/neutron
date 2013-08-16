/*
 * This file is part of the neutron project.
 * 
 * Copyright 2013 Richard Wiedenhöft <richard.wiedenhoeft@gmail.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

using Gee;

namespace Neutron.Http {
	public class Server : Object {
		private uint16 _port;
		public uint16 port { get { return _port; } set { } }

		private bool _use_tls;
		public bool use_tls { get { return _use_tls; } set { } }

		private TlsCertificate? tls_cert;
		private SocketService listener;

		private HashMap<string, Session> stored_sessions;
		private HashMap<string, RequestHandlerWrapper> request_handlers;

		public Server(uint16 port, bool use_tls, TlsCertificate? tls_cert = null) throws Error {
			assert(port != 0);

			this._port = port;
			this._use_tls = use_tls;
			this.tls_cert = tls_cert;

			/* Define listener */
			listener = new SocketService();
			listener.add_inet_port(port, null);
			listener.incoming.connect(on_incoming);

			stored_sessions = new HashMap<string, Session>();
			request_handlers = new HashMap<string, RequestHandlerWrapper>();
		}

		//TODO: Regular expressions?
		/** Adds a handler for a specific http-path */
		public void set_handler(string path, RequestHandlerFunc handler) {
			request_handlers.set(path, new RequestHandlerWrapper(handler));
		}

		/** Start handling connections */
		public void start() {
			listener.start();
		}

		/** Stop handling connections */
		public void stop() {
			listener.stop();
		}

		/** Gets the connections from listener */
		private bool on_incoming(SocketConnection conn, Object? source_object) {
			handle_connection.begin((IOStream) conn);
			return true;
		}

		/** Handle the incoming connection asynchronously */
		private async void handle_connection(IOStream conn) {
			if(_use_tls) {
				try {
					/* Wrap the connection in a TlsServerConnection */
					var tlsconn = TlsServerConnection.new(conn, tls_cert);
					yield tlsconn.handshake_async();
					conn = (IOStream) tlsconn;
				} catch(Error e) {
					return;
				}
			}

			/* Parser takes an IOStream-Object, so it does not care whether connection
			 * is encrypted or not */
			var parser = new Parser(conn);
			RequestImpl req;

			while((req = yield parser.run()) != null) {
				try {
					/* Get session_id */
					string? session_id = req.get_cookie_var("neutron_session_id");
					Session? session = null;

					if(session_id != null && stored_sessions.has_key(session_id)) {
						session = stored_sessions.get(session_id);
					}

					/* Add the session to the request-object */
					req.session = session;

					/* Check if a handler is registered for the requested path */
					if(request_handlers.has_key(req.path)) {
						/* This is used to resume this method after the finish-method
						   on the request is called */
						req.ready_callback = handle_connection.callback;

						var wrapper = request_handlers.get(req.path);
						/* Call handler */
						wrapper.handler(req);

						/* Pause until finish-method is called on the Request-Object */
						yield;

						/* Check if session was changed */
						if(req.session_changed) {
							if(req.session == null) {
								if(session != null) {	
									req.set_cookie("neutron_session_id", "deleted", -1, "/", true, use_tls);
									stored_sessions.unset(session.get_session_id());
								}
								session = null;
								session_id = null;
							} else {
								if(req.session != session) {
									if(session != null) stored_sessions.unset(session.get_session_id());
								}
								session = req.session;
								session_id = req.session.get_session_id();
								stored_sessions.set(session_id, session);
							}
						}

						/* Set/Refresh session-cookie */
						if(session != null) {
							req.set_cookie("neutron_session_id", session_id, 3600, "/", true, use_tls);
						}
					} else {
						/* Create rudimentary error-page */
						//TODO: Customize error-pages
						req.set_response_http_status(404);
						req.set_response_body("<!DOCTYPE html><html><head><meta charset=\"utf-8\" /><title>404 - Page not found</title></head><body><h1>404 - Page not found</h1></body></html>");
					}

					var respb = new StringBuilder();
					//TODO: Append name of status-code
					respb.append("HTTP/1.1 %d\r\n".printf(req.response_http_status));
					respb.append("Connection: keep-alive\r\n");

					/* Include headers and cookies in response */
					foreach(string header_line in req.response_headers) {
						respb.append("%s\r\n".printf(header_line));
					}

					/* Include body in response */
					if(req.response_body != null) {
						respb.append("Content-Length: %ld\r\n".printf(req.response_body.length));
						respb.append("\r\n");
						respb.append(req.response_body);
					} else {
						respb.append("Content-Length: 0\r\n");
						respb.append("\r\n");
					}

					/* Send response to client */
					yield conn.output_stream.write_async((uint8[]) respb.str.to_utf8());
				} catch(Error e) { }
			}

			try {
				/* Close connection */
				yield conn.close_async();
			} catch(Error e) {
				return;
			}
		}
	}

	/** 
	 * HashMap does not Support delegates as generic-types so we have to
	 * wrap the delegate in something HashMap does support.
	 */
	private class RequestHandlerWrapper : Object {
		public RequestHandlerFunc handler;

		public RequestHandlerWrapper(RequestHandlerFunc handler) {
			this.handler = handler;
		}
	}

	/** Delegate for request-handler functions */
	public delegate void RequestHandlerFunc(Request request);
}