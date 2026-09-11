import atexit
import base64
import hashlib
import http.server
import json
import os
import queue
import re
import socket
import socketserver
import struct
import sys
import threading
import time

PORT = 8080
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
DIRECTORY = os.path.join(BASE_DIR, 'control_panel')

DEFAULT_BANDS = [
    { 'id': 1, 'name': 'Low',     'color': '#00FFFF', 'freq': 80,    'gain': 0,    'q': 2.0, 'mode': 'LShv' },
    { 'id': 2, 'name': 'Low 2',   'color': '#00FF00', 'freq': 160,   'gain': 0,    'q': 2.0, 'mode': 'PEQ'  },
    { 'id': 3, 'name': 'Low Mid', 'color': '#FFFF00', 'freq': 500,   'gain': 0,    'q': 2.0, 'mode': 'PEQ'  },
    { 'id': 4, 'name': 'High Mid','color': '#FF00FF', 'freq': 1720,  'gain': 0,    'q': 1.4, 'mode': 'PEQ'  },
    { 'id': 5, 'name': 'High 2',  'color': '#FF0000', 'freq': 4370,  'gain': 0,    'q': 2.0, 'mode': 'PEQ'  },
    { 'id': 6, 'name': 'High',    'color': '#FF8800', 'freq': 10000, 'gain': 0,    'q': 2.0, 'mode': 'HShv' }
]

server_state = {
    'channels': [
        {
            'id': i,
            'name': 'Entrada' if i == 0 else f'Ch {i}',
            'volume': 70.0,
            'gain': 0.0,
            'mute': False,
            'eqEnabled': True,
            'hpf': { 'enabled': False, 'freq': 80, 'slope': 12 },
            'bands': json.loads(json.dumps(DEFAULT_BANDS))
        }
        for i in range(11)
    ]
}

state_lock = threading.Lock()
ws_clients = {}
sse_clients = set()
clients_lock = threading.Lock()

STATE_FILE = os.path.join(BASE_DIR, 'mixer_state.json')
_save_timer = None
_save_timer_lock = threading.Lock()

def load_saved_state():
    if not os.path.exists(STATE_FILE):
        return
    try:
        with open(STATE_FILE, 'r', encoding='utf-8') as f:
            saved = json.load(f)
        if isinstance(saved, dict) and 'channels' in saved and isinstance(saved['channels'], list):
            with state_lock:
                for item in saved['channels']:
                    ch_id = item.get('id')
                    if ch_id is not None and 0 <= ch_id < len(server_state['channels']):
                        server_state['channels'][ch_id].update(item)
            print(f"[Estado] Estado anterior carregado com sucesso de {STATE_FILE}!")
    except Exception as e:
        print(f"[Estado] Erro ao carregar {STATE_FILE}: {e}")

def _do_save_state():
    with state_lock:
        data = json.dumps(server_state, indent=2)
    tmp_path = STATE_FILE + '.tmp'
    try:
        with open(tmp_path, 'w', encoding='utf-8') as f:
            f.write(data)
        os.replace(tmp_path, STATE_FILE)
    except Exception as e:
        print(f"[Estado] Erro ao salvar {STATE_FILE}: {e}")

def schedule_save_state(delay=0.3):
    global _save_timer
    with _save_timer_lock:
        if _save_timer and _save_timer.is_alive():
            _save_timer.cancel()
        _save_timer = threading.Timer(delay, _do_save_state)
        _save_timer.daemon = True
        _save_timer.start()

load_saved_state()
atexit.register(_do_save_state)

WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

def encode_ws_frame(text):
    payload = text.encode('utf-8')
    length = len(payload)
    if length <= 125:
        header = struct.pack('!BB', 0x81, length)
    elif length <= 65535:
        header = struct.pack('!BBH', 0x81, 126, length)
    else:
        header = struct.pack('!BBQ', 0x81, 127, length)
    return header + payload

def decode_ws_frame(data):
    if len(data) < 2:
        return None, 0
    b1, b2 = data[0], data[1]
    opcode = b1 & 0x0F
    masked = bool(b2 & 0x80)
    payload_len = b2 & 0x7F
    offset = 2
    if payload_len == 126:
        if len(data) < 4:
            return None, 0
        payload_len = struct.unpack('!H', data[2:4])[0]
        offset = 4
    elif payload_len == 127:
        if len(data) < 10:
            return None, 0
        payload_len = struct.unpack('!Q', data[2:10])[0]
        offset = 10
    mask_key = None
    if masked:
        if len(data) < offset + 4:
            return None, 0
        mask_key = data[offset:offset+4]
        offset += 4
    if len(data) < offset + payload_len:
        return None, 0
    payload = bytearray(data[offset:offset+payload_len])
    if masked and mask_key:
        for i in range(len(payload)):
            payload[i] ^= mask_key[i % 4]
    return (opcode, bytes(payload)), offset + payload_len

def broadcast(event_type, data):
    msg_str = json.dumps({'type': event_type, 'data': data})
    ws_frame = encode_ws_frame(msg_str)
    sse_payload = f"event: {event_type}\ndata: {json.dumps(data)}\n\n".encode('utf-8')

    with clients_lock:
        dead_ws = []
        for sock in list(ws_clients.keys()):
            try:
                sock.sendall(ws_frame)
            except Exception:
                dead_ws.append(sock)
        for s in dead_ws:
            ws_clients.pop(s, None)

        dead_sse = []
        for q in list(sse_clients):
            try:
                q.put_nowait(sse_payload)
            except Exception:
                dead_sse.append(q)
        for q in dead_sse:
            sse_clients.discard(q)

def get_connected_count():
    with clients_lock:
        return len(ws_clients) + len(sse_clients)

def broadcast_clients_count():
    count = get_connected_count()
    broadcast('clients_count', {'count': count})
    print(f"[STATUS] Total de aparelhos sincronizados: {count}")

def apply_sync_payload(payload):
    event_type = payload.get('type')
    ch_idx = payload.get('channel')

    with state_lock:
        if ch_idx is not None and 0 <= ch_idx < len(server_state['channels']):
            ch = server_state['channels'][ch_idx]
            if event_type == 'volume':
                ch['volume'] = float(payload.get('value', 70))
            elif event_type == 'gain':
                ch['gain'] = float(payload.get('value', 0.0))
            elif event_type == 'mute':
                ch['mute'] = bool(payload.get('value', False))
            elif event_type == 'name':
                ch['name'] = str(payload.get('value', ''))[:8]
            elif event_type == 'eq':
                if 'bands' in payload:
                    ch['bands'] = payload['bands']
                if 'enabled' in payload:
                    ch['eqEnabled'] = bool(payload['enabled'])
                if 'hpf' in payload:
                    ch['hpf'] = payload['hpf']

    schedule_save_state()
    broadcast('update', payload)

class AudioMixerHandler(http.server.SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIRECTORY, **kwargs)

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError, socket.error):
            pass

    def do_GET(self):
        # 1. WebSocket Upgrade no mesmo endpoint/porta
        if self.headers.get("Upgrade", "").lower() == "websocket":
            self.handle_websocket()
            return

        # 2. Roteamento de páginas com cabeçalhos rigorosos Anti-Cache
        if self.path in ('/', '/index.html'):
            self.path = '/preview.html'

        # 3. Server-Sent Events (SSE) como fallback
        if self.path == '/events':
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Cache-Control', 'no-cache, no-transform')
            self.send_header('Connection', 'keep-alive')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()

            client_queue = queue.Queue(maxsize=150)
            client_ip = self.client_address[0]
            with clients_lock:
                sse_clients.add(client_queue)
            print(f"[SSE] Aparelho conectado de {client_ip} (Total: {get_connected_count()})")
            broadcast_clients_count()

            with state_lock:
                init_msg = f"event: init\ndata: {json.dumps(server_state)}\n\n".encode('utf-8')
            try:
                self.wfile.write(init_msg)
                self.wfile.flush()
            except Exception:
                with clients_lock:
                    sse_clients.discard(client_queue)
                return

            try:
                while True:
                    try:
                        msg = client_queue.get(timeout=10)
                        self.wfile.write(msg)
                        self.wfile.flush()
                    except queue.Empty:
                        self.wfile.write(b": heartbeat\n\n")
                        self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError, socket.error):
                pass
            finally:
                with clients_lock:
                    sse_clients.discard(client_queue)
                print(f"[SSE] Aparelho desconectado de {client_ip} (Total: {get_connected_count()})")
                broadcast_clients_count()
            return

        if self.path in ('/api/state', '/api/status', '/channels'):
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            with state_lock:
                data = json.dumps(server_state, indent=2).encode('utf-8')
            self.wfile.write(data)
            return

        return super().do_GET()

    def handle_websocket(self):
        key = self.headers.get("Sec-WebSocket-Key", "")
        accept = base64.b64encode(hashlib.sha1((key + WS_GUID).encode()).digest()).decode()
        self.send_response(101, "Switching Protocols")
        self.send_header("Upgrade", "websocket")
        self.send_header("Connection", "Upgrade")
        self.send_header("Sec-WebSocket-Accept", accept)
        self.end_headers()

        client_ip = self.client_address[0]
        sock = self.request
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

        with clients_lock:
            ws_clients[sock] = client_ip
        print(f"[WebSocket] Aparelho conectado de: {client_ip} (Total: {get_connected_count()})")
        broadcast_clients_count()

        # Envia estado inicial
        with state_lock:
            init_msg = json.dumps({'type': 'init', 'data': server_state})
        sock.sendall(encode_ws_frame(init_msg))

        buf = bytearray()
        try:
            while True:
                chunk = sock.recv(4096)
                if not chunk:
                    break
                buf.extend(chunk)
                while True:
                    frame, consumed = decode_ws_frame(buf)
                    if frame is None:
                        break
                    buf = buf[consumed:]
                    opcode, payload = frame
                    if opcode == 0x08:
                        return
                    elif opcode == 0x09:
                        sock.sendall(struct.pack('!BB', 0x8A, 0))
                    elif opcode == 0x01:
                        try:
                            msg = json.loads(payload.decode('utf-8'))
                            apply_sync_payload(msg)
                        except Exception as e:
                            print(f"[WS Payload Erro]: {e}")
        except Exception:
            pass
        finally:
            with clients_lock:
                ws_clients.pop(sock, None)
            print(f"[WebSocket] Aparelho desconectado de: {client_ip} (Total: {get_connected_count()})")
            broadcast_clients_count()

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'GET, POST, PUT, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        if self.path == '/api/sync':
            content_len = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_len).decode('utf-8') if content_len > 0 else '{}'
            try:
                payload = json.loads(body)
                apply_sync_payload(payload)
            except Exception as e:
                print(f"[POST Sync Erro]: {e}")

            self.send_response(200)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(b'{"status":"ok"}')
            return

        self.send_response(404)
        self.end_headers()

    def do_PUT(self):
        vol_match = re.match(r'^/channel/(\d+)/volume/?$', self.path)
        gain_match = re.match(r'^/channel/(\d+)/gain/?$', self.path)
        mute_match = re.match(r'^/channel/(\d+)/mute/?$', self.path)

        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8') if length > 0 else '{}'
        try:
            data = json.loads(body) if body else {}
        except Exception:
            data = {}

        if vol_match:
            ch_id = int(vol_match.group(1))
            val_raw = data.get('value', 0)
            val_pct = round((val_raw / 255.0) * 100.0, 1)

            apply_sync_payload({
                'type': 'volume',
                'channel': ch_id,
                'value': val_pct,
                'clientId': 'esp32'
            })

            print(f"[ESP32 API] Canal {ch_id}: Volume {val_raw} ({val_pct}%)")
            self.send_response(200)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
            return

        if gain_match:
            ch_id = int(gain_match.group(1))
            val_gain = float(data.get('value', data.get('gain', 0.0)))

            apply_sync_payload({
                'type': 'gain',
                'channel': ch_id,
                'value': val_gain,
                'clientId': 'esp32'
            })

            print(f"[ESP32 API] Canal {ch_id}: Ganho {val_gain:+.1f} dB")
            self.send_response(200)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
            return

        if mute_match:
            ch_id = int(mute_match.group(1))
            state = bool(data.get('state', 0))

            apply_sync_payload({
                'type': 'mute',
                'channel': ch_id,
                'value': state,
                'clientId': 'esp32'
            })

            print(f"[ESP32 API] Canal {ch_id}: Mute alterado para {state}")
            self.send_response(200)
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'OK')
            return

        self.send_response(404)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(b'Not Found')

    def end_headers(self):
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store, no-cache, must-revalidate, max-age=0')
        self.send_header('Pragma', 'no-cache')
        self.send_header('Expires', '0')
        super().end_headers()

class ThreadedTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    allow_reuse_address = True
    daemon_threads = True

def run():
    with ThreadedTCPServer(("0.0.0.0", PORT), AudioMixerHandler) as httpd:
        print("==================================================")
        print("  Servidor Audio Mixer com WEBSOCKET & SSE")
        print(f"  URL Local:   http://localhost:{PORT}")
        print(f"  Celular:     http://192.168.31.236:{PORT}")
        print(f"  Interface:   http://localhost:{PORT}/preview.html")
        print("==================================================")
        sys.stdout.flush()
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            _do_save_state()
            print("\nServidor encerrado. Estado salvo.")

if __name__ == '__main__':
    run()
