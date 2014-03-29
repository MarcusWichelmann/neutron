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

using Gee;

/**
 * Parses http-request and body
 */
private class Neutron.Http.Parser : Object {
	private int timeout;
	private IOStream stream;
	ByteArray buffer;
	private uint max_size;

	/**
	 * Instantiates a Parser that reads from the supplied IOStream 
	 */
	public Parser(IOStream stream, int timeout, uint max_size) {
		this.stream = stream;
		this.timeout = timeout;
		this.max_size = max_size;
		buffer = new ByteArray();
	}

	private async void refill_buffer() throws Error{
		var buf = new uint8[1024];

		Cancellable? timeout_provider = null;
		if(timeout > 0) {
			timeout_provider = new Cancellable();
			Timeout.add_seconds((uint) timeout, () => {
				timeout_provider.cancel();
				return true;
			});
		}

		var reclen = yield stream.input_stream.read_async(buf, Priority.DEFAULT, timeout_provider);
		if(reclen == 0) throw new HttpError.CONNECTION_CLOSED("Connection closed");

		buffer.append(buf[0:reclen]);
	}

	private async char get_char() throws Error {
		while(buffer.len == 0) yield refill_buffer();
		var result = buffer.data[0];
		buffer.remove_index(0);

		return (char) result;
	}

	private async char[] get_chars(uint size) throws Error {
		while(buffer.len < size) yield refill_buffer();
		var result = buffer.data[0:size];
		buffer.remove_range(0,size);
		return (char[]) result;
	}

	/**
	 * Get the next request 
	 */
	public async RequestImpl? run() {
		var headers = new HashMap<string, string>();
		var body = new HashMap<string, string>();
		var gets = new HashMap<string, string>();
		var cookies = new HashMap<string, string>();
		string path;
		uint size = 0;

		int state = -1;

		var method = new StringBuilder();
		var url = new StringBuilder();
		var httpver = new StringBuilder();
		StringBuilder? header_key = null;
		StringBuilder header_val = null;
		
		try {
			var get_next_char = true;
			char nextchar = '\r';
			while(state < 9) {
				if(size >= max_size) return null;

				if(get_next_char) {
					nextchar = yield get_char();
					size++;
				}
				else get_next_char = true;

				switch(state) {
				case -1:
					if(nextchar != '\r' && nextchar != '\n') {
						state = 0;
						get_next_char = false;
						continue;
					}
					break;
				case 0:
					if(nextchar == ' ') {
						state = 1;
						continue;
					}
					if(nextchar == '\r' || nextchar == '\n') {
						return null;
					}

					method.append_c(nextchar);
					break;
				case 1:
					if(nextchar == ' ') {
						state = 2;
						continue;
					}
					if(nextchar == '\r' || nextchar == '\n') {
						return null;
					}

					url.append_c(nextchar);
					break;
				case 2:
					if(nextchar == '\r') {
						state = 3;
						continue;
					}
					if(nextchar == '\n') {
						state = 4;
						header_key = new StringBuilder();
						continue;
					}
					if(nextchar == ' ') {
						return null;
					}

					httpver.append_c(nextchar);
					break;
				case 3:
					if(nextchar != '\n') {
						return null;
					} else {
						state = 4;
						header_key = new StringBuilder();
					}
					break;
				case 4:
					if(nextchar == ':') {
						state = 5;
						continue;
					}
					if(nextchar == ' ') {
						return null;
					}
					if(nextchar == '\r') {
						state = 8;
						continue;
					}
					if(nextchar == '\n') {
						state = 9;
						continue;
					}

					header_key.append_c(nextchar);
					break;
				case 5:
					if(nextchar == ' ') {
						state = 6;
						header_val = new StringBuilder();
						continue;
					} else {
						return null;
					}
				case 6:
					if(nextchar == '\r') {
						state = 7;
						var key_str = header_key.str.down();
						headers.set(key_str, header_val.str);
						header_key = new StringBuilder();
						continue;
					}
					if(nextchar == '\n') {
						state = 4;
						var key_str = header_key.str.down();
						headers.set(key_str, header_val.str);
						header_key = new StringBuilder();
						continue;
					}

					header_val.append_c(nextchar);
					break;
				case 7:
					if(nextchar == '\n') {
						state = 4;
					}
					else {
						return null;
					}
					break;
				case 8:
					if(nextchar == '\n') {
						state = 9;
					}
					else {
						return null;
					}
					break;
				}
			}

			var urlarr = url.str.split("?",2);
			if(urlarr[0][urlarr[0].length-1] == '/' && urlarr[0].length > 1) {
				path = urlarr[0].substring(0, urlarr[0].length-1);
			} else path = urlarr[0];
			if(urlarr.length == 2) parse_varstring(gets, urlarr[1]);

			if(headers.has_key("cookie")) {
				var cookiearr = headers.get("cookie").split(";");
				foreach(string cookie in cookiearr) {
					var cookiesplit = cookie.split("=", 2);
					if(cookiesplit.length != 2) continue;
					else cookies.set(cookiesplit[0].strip(), cookiesplit[1].strip());
				}
			}

			if(headers.has_key("content-length") && method.str == "POST") {
				var clen = (uint) uint64.parse(headers.get("content-length"));
				var bodybuilder = new StringBuilder();

				size += clen;
				if(size > max_size) return null;

				bodybuilder.append((string) yield get_chars(clen));
				parse_varstring(body, bodybuilder.str);
			}
		} catch(Error e) {
			return null;
		}

		return new RequestImpl(method.str, path, gets, body, cookies, headers);
	}

	private void parse_varstring(HashMap<string, string> map, string varstring) {
		var reqarr = varstring.split("&");
		foreach(string reqpair in reqarr) {
			var reqparr = reqpair.split("=", 2);
			string key = reqparr[0];
			string val;
			if(reqparr.length == 1) val = "";
			else val = reqparr[1];
			var ue_key = Uri.unescape_string(key);
			var ue_val = Uri.unescape_string(val);
			if(ue_key == null) return;
			if(ue_val == null) ue_val = "";
			map.set(ue_key, ue_val);
		}
	}
}

