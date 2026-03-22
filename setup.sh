#!/bin/bash

# 0. Bestehende Installation für Update stoppen
SERVICE_NAME="iobroker-script-restore.service"

if [ -f "/etc/systemd/system/$SERVICE_NAME" ]; then
    echo "🔄 Bestehende Installation gefunden. Stoppe den Service für das Update..."
    sudo systemctl stop "$SERVICE_NAME"
fi

# Kurze Pause
sleep 2

# 1. Port-Abfrage
while true; do
    read -p "Auf welchem Port soll die App laufen? [5000]: " PORT
    PORT=${PORT:-5000}
    if ss -tuln | grep -q ":$PORT "; then
        echo "⚠️  Warnung: Der Port $PORT ist belegt."
    else
        echo "✅ Port $PORT ist frei."
        break
    fi
done

# 2. Autostart-Abfrage
read -p "Soll die App in den Autostart (systemd) eingetragen werden? [Y/n]: " AUTOSTART
AUTOSTART=${AUTOSTART:-Y}

# 3. Installation der Abhängigkeiten
echo "Installiere Abhängigkeiten..."
sudo apt update && sudo apt install -y python3 python3-flask tar

# Arbeitsverzeichnis erstellen
INSTALL_DIR=$(pwd)/iobroker-script-restore
mkdir -p "$INSTALL_DIR/templates"
cd "$INSTALL_DIR" || exit

# 4. App-Logik (Python) erstellen
echo "Erstelle app.py..."
cat <<EOF > app.py
import os
import tarfile
import json
from flask import Flask, render_template, request, jsonify, session, redirect, url_for

app = Flask(__name__)
app.secret_key = 'scriptrestore-key-2024'
app.config['MAX_CONTENT_LENGTH'] = 500 * 1024 * 1024

PASSWORD = "dagrae"

def process_item(key, val, scripts_list):
    key_str = str(key)
    if isinstance(val, dict) and (val.get('type') == 'script' or key_str.startswith('script.js.')):
        if val.get('type') in ['channel', 'device', 'folder', 'meta']:
            return
        c = val.get('common')
        if not isinstance(c, dict) or ('engineType' not in c and 'source' not in c):
            return
            
        raw = str(c.get('engineType', 'JS')).lower()
        stype = 'TypeScript' if 'ts' in raw or 'typescript' in raw else 'Blockly' if 'blockly' in raw else 'Rules' if 'rules' in raw else 'JS'
        src = c.get('source', '')
        
        name_obj = c.get('name')
        if isinstance(name_obj, dict):
            name = name_obj.get('de') or name_obj.get('en') or list(name_obj.values())[0]
        else:
            name = name_obj or key_str.split('.')[-1]
            
        path = key_str[10:] if key_str.startswith('script.js.') else key_str
            
        scripts_list.append({
            'name': name,
            'path': path,
            'type': stype,
            'source': src
        })

def parse_file_obj(file_obj, filename):
    scripts = []
    try:
        if filename.endswith('.jsonl'):
            for line in file_obj:
                try:
                    l = line.decode('utf-8', errors='ignore').strip()
                    if l:
                        item = json.loads(l)
                        process_item(item.get('id') or item.get('_id'), item.get('value') or item.get('doc') or item, scripts)
                except Exception:
                    continue
        else:
            content = file_obj.read().decode('utf-8', errors='ignore')
            if content.lstrip().startswith('{"id"'):
                for l in content.splitlines():
                    l = l.strip()
                    if l:
                        try:
                            item = json.loads(l)
                            process_item(item.get('id') or item.get('_id'), item.get('value') or item.get('doc') or item, scripts)
                        except Exception:
                            continue
            else:
                data = json.loads(content)
                for k, v in data.items():
                    process_item(k, v, scripts)
    except Exception as e:
        print(f"Fehler beim Parsen: {e}")
        
    return scripts

LOGIN_HTML = """<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login - ioBroker Script Restore</title>
    <style>
        body{display:flex;align-items:center;justify-content:center;height:100vh;margin:0;font-family:system-ui,sans-serif;background:#212529;}
        .box{background:#fff;border-radius:8px;padding:2rem;width:320px;box-shadow:0 4px 24px rgba(0,0,0,0.4);}
        h2{margin:0 0 1.5rem;color:#212529;font-size:1.25rem;text-align:center;}
        input[type=password]{width:100%;padding:.5rem .75rem;border:1px solid #ced4da;border-radius:4px;font-size:1rem;box-sizing:border-box;margin-bottom:1rem;}
        button{width:100%;padding:.5rem;background:#0d6efd;color:#fff;border:none;border-radius:4px;font-size:1rem;font-weight:bold;cursor:pointer;}
        button:hover{background:#0b5ed7;}
        .error{color:#dc3545;font-size:.875rem;margin-bottom:1rem;text-align:center;}
    </style>
</head>
<body>
    <div class="box">
        <h2>ioBroker Script Restore</h2>
        {error}
        <form method="POST">
            <input type="password" name="password" placeholder="Passwort" autofocus required>
            <button type="submit">Anmelden</button>
        </form>
    </div>
</body>
</html>"""

@app.route('/login', methods=['GET', 'POST'])
def login():
    error = ''
    if request.method == 'POST':
        if request.form.get('password') == PASSWORD:
            session['auth'] = True
            return redirect('/')
        error = '<p class="error">Falsches Passwort</p>'
    return LOGIN_HTML.replace('{error}', error)

@app.route('/logout')
def logout():
    session.clear()
    return redirect('/login')

@app.route('/', methods=['GET', 'POST'])
def index():
    if not session.get('auth'):
        return redirect('/login')
    if request.method == 'POST':
        scripts = []
        if 'backup' in request.files:
            f = request.files['backup']
            if f.filename.endswith('.gz') or f.filename.endswith('.tar'):
                try:
                    with tarfile.open(fileobj=f, mode="r:*") as tar:
                        for m in tar:
                            if m.isfile() and any(t in m.name for t in ['objects.json', 'objects.jsonl', 'script.json']):
                                extracted_file = tar.extractfile(m)
                                if extracted_file:
                                    scripts = parse_file_obj(extracted_file, m.name)
                                break
                except Exception as e:
                    print(f"Fehler beim Entpacken: {e}")
            else:
                scripts = parse_file_obj(f, f.filename)
                
        sorted_scripts = sorted(scripts, key=lambda x: str(x['name']).lower())
        return jsonify(sorted_scripts)
        
    return render_template('index.html')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=$PORT)
EOF

# 5. Frontend (HTML/CSS/JS) erstellen
echo "Erstelle templates/index.html..."
cat <<EOF > templates/index.html
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>ioBroker Script Restore</title>
    <link rel="icon" href="data:,">
    <style>
        :root {
            --primary: #0d6efd;
            --primary-hover: #0b5ed7;
            --success: #198754;
            --success-hover: #157347;
            --bg-light: #f8f9fa;
            --bg-dark: #212529;
            --bg-panel: #1e1e1e;
            --border: #dee2e6;
            --font-main: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        }
        *, *::before, *::after { box-sizing: border-box; }
        
        body, html { 
            height: 100%; 
            margin: 0; 
            padding: 0; 
            display: flex; 
            flex-direction: column; 
            overflow: hidden; 
            font-family: var(--font-main); 
            background-color: var(--bg-light); 
            color: #212529; 
        }
        
        /* Navbar */
        .navbar { 
            display: flex; 
            align-items: center; 
            justify-content: space-between; 
            min-height: 60px; 
            background-color: var(--bg-dark); 
            padding: 10px 1.5rem; 
            box-shadow: 0 2px 4px rgba(0,0,0,0.1); 
            color: white; 
            flex-shrink: 0;
            z-index: 100;
        }
        .navbar-brand { font-size: 1.25rem; white-space: nowrap; }
        .search-form { display: flex; width: 550px; max-width: 100%; }
        .search-form input { flex: 1; padding: 0.375rem 0.75rem; border: 1px solid #ced4da; border-radius: 4px 0 0 4px; font-size: 0.875rem; outline: none; background: white; color: #212529; line-height: 1.5; min-width: 0; }
        .search-form input::file-selector-button { padding: 0.15rem 0.6rem; margin-right: 10px; border: 1px solid #ced4da; border-radius: 3px; background: #e9ecef; color: #212529; cursor: pointer; transition: 0.2s; font-weight: 500; }
        .search-form button { background: var(--primary); color: white; border: none; padding: 0 1.5rem; font-weight: bold; font-size: 0.875rem; border-radius: 0 4px 4px 0; cursor: pointer; transition: 0.2s; white-space: nowrap; }
        .search-form button:hover { background: var(--primary-hover); }

        /* Main Container */
        .main-container { display: flex; flex: 1; width: 100%; overflow: hidden; flex-direction: row; }
        
        /* Sidebar */
        .sidebar { width: 300px; min-width: 200px; max-width: 60vw; display: flex; flex-direction: column; background: white; height: 100%; flex-shrink: 0; }
        .content-area { flex: 1; display: flex; flex-direction: column; background: var(--bg-panel); height: 100%; position: relative; overflow: hidden; min-width: 0; }

        /* Resizer (Maus / Touch) */
        .resizer { 
            width: 4px; 
            background-color: var(--border); 
            cursor: col-resize; 
            transition: background-color 0.2s; 
            z-index: 10; 
            flex-shrink: 0; 
            touch-action: none;
        }
        .resizer:hover, .resizer.resizing { background-color: var(--primary); width: 6px; }

        /* Sidebar Elements */
        .sidebar-header { padding: 0.5rem; border-bottom: 1px solid var(--border); display: flex; gap: 5px; }
        .sidebar-header input { flex: 1; padding: 0.375rem 0.75rem; border: 1px solid #ced4da; border-radius: 4px; font-size: 1rem; outline: none; min-width: 0; }
        
        .btn-icon { background: #e9ecef; border: 1px solid #ced4da; border-radius: 4px; padding: 0 10px; cursor: pointer; color: #444; transition: 0.2s; display: flex; align-items: center; justify-content: center; font-size: 1.1rem; }
        .btn-icon:hover { background: #dde0e3; }

        .script-list { flex: 1; overflow-y: auto; padding: 5px 0; }
        
        /* Tree View Styling */
        .tree-folder { cursor: pointer; padding: 8px 15px; font-weight: 500; color: #333; display: flex; align-items: center; user-select: none; transition: 0.1s; border-bottom: 1px solid transparent; }
        .tree-folder:hover { background-color: #f0f7ff; }
        .folder-icon { display: inline-block; width: 16px; margin-right: 8px; transition: transform 0.2s; opacity: 0.7; font-size: 0.85em; }
        .folder-icon.open { transform: rotate(90deg); }
        .tree-children { display: none; }
        .tree-children.open { display: block; }
        
        .script-item { cursor: pointer; padding: 10px 15px; transition: background-color 0.1s; display: flex; justify-content: space-between; align-items: center; border-bottom: 1px solid #eee; }
        .tree-script { padding-left: 35px; border-bottom: none; } 
        .tree-children .tree-children .tree-script { padding-left: 55px; } 
        .tree-children .tree-children .tree-children .tree-script { padding-left: 75px; } 
        .tree-children .tree-children .tree-folder { padding-left: 35px; }
        .tree-children .tree-children .tree-children .tree-folder { padding-left: 55px; }
        
        .script-item:hover { background-color: #f0f7ff; }
        .script-item.active { background-color: #e7f1ff; border-left: 4px solid var(--primary); padding-left: calc(15px - 4px); }
        .tree-script.active { padding-left: calc(35px - 4px); }
        .tree-children .tree-children .tree-script.active { padding-left: calc(55px - 4px); }
        .tree-children .tree-children .tree-children .tree-script.active { padding-left: calc(75px - 4px); }
        
        .script-name { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-weight: 400; font-size: 0.95rem; }
        .type-badge { font-size: 10px; padding: 3px 6px; border-radius: 4px; font-weight: bold; text-transform: uppercase; margin-left: 10px; flex-shrink: 0; }
        .badge-Blockly { background-color: #61696e; color: white; }
        .badge-JS { background-color: #f4d436; color: #212529; }
        .badge-TypeScript { background-color: #3375c2; color: white; }
        .badge-Rules { background-color: #05194a; color: white; }
        .icon-file { opacity: 0.6; margin-right: 5px; }

        /* Action Bar */
        .action-bar { background: #2d2d2d; padding: 10px 20px; border-bottom: 1px solid #444; flex-shrink: 0; display: none; }
        .action-bar-inner { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 10px; }
        .btn { display: inline-block; font-weight: 500; text-align: center; cursor: pointer; padding: 0.35rem 0.75rem; font-size: 0.875rem; border-radius: 4px; transition: 0.15s; border: 1px solid transparent; background: transparent; text-decoration: none; }
        .btn-group { display: flex; flex-wrap: nowrap; }
        .btn-group .btn { border-radius: 0; border-right-width: 0; }
        .btn-group .btn:first-child { border-radius: 4px 0 0 4px; }
        .btn-group .btn:last-child { border-radius: 0 4px 4px 0; border-right-width: 1px; }
        .btn-outline-light { color: #f8f9fa; border-color: #f8f9fa; }
        .btn-outline-light:hover, .btn-outline-light.active { background: #f8f9fa; color: #000; }
        .btn-outline-primary { color: var(--primary); border-color: var(--primary); }
        .btn-outline-primary:hover, .btn-outline-primary.active { background: var(--primary); color: white; }
        .btn-outline-success { color: var(--success); border-color: var(--success); }
        .btn-outline-success:hover, .btn-outline-success.active { background: var(--success); color: white; }
        .btn-primary { background: var(--primary); color: white; border-color: var(--primary); font-weight: bold; }
        .btn-primary:hover { background: var(--primary-hover); }

        /* Code Area & Zeilennummern */
        .code-display { 
            font-family: 'Consolas', 'Courier New', monospace; 
            font-size: 13px; 
            color: #d4d4d4; 
            flex: 1; 
            overflow: auto; 
            margin: 0; 
            padding: 15px 0;
            counter-reset: line; 
            line-height: 1.5;
            white-space: pre;
        }
        .code-line { display: block; padding-right: 15px; }
        .code-line:hover { background-color: rgba(255, 255, 255, 0.03); }
        .code-line::before {
            counter-increment: line;
            content: counter(line);
            display: inline-block;
            width: 3.5em;
            margin-right: 1.5em;
            color: #6c757d; 
            text-align: right;
            border-right: 1px solid #444; 
            padding-right: 1em;
            user-select: none; 
        }
        .code-empty { display: flex; flex-direction: column; align-items: center; justify-content: center; height: 100%; color: #6a9955; font-family: 'Consolas', monospace; font-size: 14px; flex: 1; text-align: center; padding: 20px; }

        /* Loader */
        #loader { position: fixed; top: 0; left: 0; width: 100%; height: 100%; background: rgba(255,255,255,0.95); z-index: 9999; display: none; flex-direction: column; align-items: center; justify-content: center; }
        .spinner { width: 4rem; height: 4rem; border: 0.4em solid rgba(13, 110, 253, 0.2); border-top-color: var(--primary); border-radius: 50%; animation: spin 1s linear infinite; margin-bottom: 1rem; }
        @keyframes spin { 100% { transform: rotate(360deg); } }
        #progressContainer { position: relative; width: 4rem; height: 4rem; margin-bottom: 1rem; }
        #progressCircle { width: 100%; height: 100%; border-radius: 50%; background: conic-gradient(var(--primary) 0%, #e9ecef 0%); transition: background 0.1s; }
        .progress-inner { position: absolute; top: 50%; left: 50%; transform: translate(-50%, -50%); width: 3.2rem; height: 3.2rem; background: rgba(255,255,255,0.95); border-radius: 50%; display: flex; align-items: center; justify-content: center; }
        #progressPercent { font-size: 0.9rem; font-weight: bold; color: var(--primary); }

        /* Responsive Design für Smartphones */
        @media (max-width: 768px) {
            .navbar { flex-direction: column; gap: 10px; padding: 15px 10px; }
            .search-form { width: 100%; }
            .main-container { flex-direction: column; }
            .sidebar { width: 100% !important; max-width: 100%; height: 40vh; min-height: 150px; border-right: none; }
            .resizer { width: 100% !important; height: 4px; cursor: row-resize; }
            .resizer:hover, .resizer.resizing { height: 6px; width: 100% !important; }
            .action-bar-inner { flex-direction: column; align-items: stretch; }
            .btn-group { justify-content: center; width: 100%; }
            .action-bar .gap-2 { display: flex; justify-content: center; width: 100%; }
            .action-bar .btn { flex: 1; }
        }
    </style>
</head>
<body>
    <div id="loader">
        <div id="progressContainer">
            <div id="progressCircle"></div>
            <div class="progress-inner"><span id="progressPercent">0%</span></div>
        </div>
        <div id="spinnerElement" class="spinner" style="display: none;"></div>
        <h4 id="loaderText">Lade Backup hoch...</h4>
    </div>

    <nav class="navbar">
        <span class="navbar-brand">ioBroker Script <strong>Restore</strong></span>
        <form class="search-form" onsubmit="handleUpload(event)">
            <input type="file" name="backup" required accept=".tar,.gz,.jsonl,.json">
            <button type="submit">Backup Laden</button>
        </form>
        <a href="/logout" style="color:#adb5bd;font-size:0.875rem;text-decoration:none;margin-left:1rem;white-space:nowrap;">Abmelden</a>
    </nav>

    <div class="main-container">
        <div class="sidebar" id="sidebar">
            <div class="sidebar-header">
                <input type="text" id="q" placeholder="Suche in Namen, Ordner & Code...">
                <button id="expandToggleBtn" class="btn-icon" onclick="toggleExpandAll()" title="Alle Ordner aufklappen">📂</button>
            </div>
            <div id="list" class="script-list"></div>
        </div>
        
        <div class="resizer" id="resizer"></div>

        <div class="content-area">
            <div class="action-bar" id="actionBar">
                <div class="action-bar-inner">
                    <div class="btn-group" id="viewSwitcher"></div>
                    <div class="gap-2">
                        <button onclick="copyCode(this)" class="btn btn-outline-light">Code Kopieren</button>
                        <button onclick="downloadActive()" class="btn btn-primary" id="dlBtn">Download</button>
                    </div>
                </div>
            </div>
            <div id="codeContainer" class="code-empty">
                <div>
                    <strong>Willkommen bei ioBroker Script Restore!</strong><br><br>
                    Lade oben rechts ein Backup hoch, um Skripte wiederherzustellen.
                </div>
            </div>
        </div>
    </div>

    <script>
        // Verhindert XSS/Fehler beim Rendern von < und > in HTML
        function escapeHTML(str) {
            if (!str) return '';
            return String(str).replace(/[&<>'"]/g, tag => ({
                '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;'
            }[tag]));
        }

        // === Resizer Logik ===
        const resizer = document.getElementById('resizer');
        const sidebar = document.getElementById('sidebar');
        let startX = 0, startY = 0, startW = 0, startH = 0, isMobile = false;

        const mouseDownHandler = function(e) {
            isMobile = window.innerWidth <= 768;
            startX = e.clientX || (e.touches ? e.touches[0].clientX : 0);
            startY = e.clientY || (e.touches ? e.touches[0].clientY : 0);
            
            const styles = window.getComputedStyle(sidebar);
            startW = parseInt(styles.width, 10);
            startH = parseInt(styles.height, 10);

            document.body.style.userSelect = 'none';
            document.body.style.cursor = isMobile ? 'row-resize' : 'col-resize';
            resizer.classList.add('resizing');

            document.addEventListener('mousemove', mouseMoveHandler);
            document.addEventListener('mouseup', mouseUpHandler);
            document.addEventListener('touchmove', mouseMoveHandler, { passive: false });
            document.addEventListener('touchend', mouseUpHandler);
        };

        const mouseMoveHandler = function(e) {
            const currentX = e.clientX || (e.touches ? e.touches[0].clientX : 0);
            const currentY = e.clientY || (e.touches ? e.touches[0].clientY : 0);
            
            if (isMobile) {
                const dy = currentY - startY;
                sidebar.style.height = \`\${startH + dy}px\`;
                sidebar.style.width = '100%'; 
            } else {
                const dx = currentX - startX;
                sidebar.style.width = \`\${startW + dx}px\`;
                sidebar.style.height = '100%';
            }
        };

        const mouseUpHandler = function() {
            resizer.classList.remove('resizing');
            document.body.style.removeProperty('cursor');
            document.body.style.removeProperty('user-select');

            document.removeEventListener('mousemove', mouseMoveHandler);
            document.removeEventListener('mouseup', mouseUpHandler);
            document.removeEventListener('touchmove', mouseMoveHandler);
            document.removeEventListener('touchend', mouseUpHandler);
        };

        resizer.addEventListener('mousedown', mouseDownHandler);
        resizer.addEventListener('touchstart', mouseDownHandler, { passive: true });
        
        window.addEventListener('resize', () => {
            sidebar.style.width = '';
            sidebar.style.height = '';
        });
        // ==========================================================

        let scriptsData = [];
        let cur = { index: -1 }; 
        const openFolders = new Set(); 
        let isAllExpanded = false;

        function toggleExpandAll() {
            isAllExpanded = !isAllExpanded;
            const btn = document.getElementById('expandToggleBtn');
            btn.innerHTML = isAllExpanded ? '📁' : '📂';
            btn.title = isAllExpanded ? 'Alle Ordner einklappen' : 'Alle Ordner aufklappen';
            
            document.querySelectorAll('.tree-folder').forEach(el => {
                const path = el.dataset.path;
                const icon = el.querySelector('.folder-icon');
                const children = el.nextElementSibling;
                
                if (isAllExpanded) {
                    icon.classList.add('open');
                    children.classList.add('open');
                    openFolders.add(path);
                } else {
                    icon.classList.remove('open');
                    children.classList.remove('open');
                    openFolders.delete(path);
                }
            });
        }

        async function handleUpload(e) {
            e.preventDefault(); 
            const form = e.target;
            const fileInput = form.querySelector('input[type="file"]');
            if (!fileInput.files.length) return;

            document.getElementById('loader').style.display = 'flex';
            document.getElementById('progressContainer').style.display = 'block';
            document.getElementById('spinnerElement').style.display = 'none';
            document.getElementById('progressCircle').style.background = \`conic-gradient(var(--primary) 0%, #e9ecef 0%)\`;
            document.getElementById('progressPercent').innerText = '0%';
            document.getElementById('loaderText').innerText = 'Lade Backup hoch...';

            const formData = new FormData(form);
            const xhr = new XMLHttpRequest();

            xhr.upload.onprogress = function(event) {
                if (event.lengthComputable) {
                    let percent = Math.round((event.loaded / event.total) * 100);
                    document.getElementById('progressCircle').style.background = \`conic-gradient(var(--primary) \${percent}%, #e9ecef \${percent}%)\`;
                    document.getElementById('progressPercent').innerText = percent + '%';
                    
                    if (percent >= 100) {
                        setTimeout(() => {
                            document.getElementById('progressContainer').style.display = 'none';
                            document.getElementById('spinnerElement').style.display = 'block';
                            document.getElementById('loaderText').innerText = 'Verarbeite Daten...';
                        }, 250); 
                    }
                }
            };

            xhr.onload = function() {
                if (xhr.status === 200) {
                    scriptsData = JSON.parse(xhr.responseText);
                    cur = { index: -1 }; 
                    renderList();
                    
                    document.getElementById('loader').style.display = 'none';
                    document.getElementById('actionBar').style.display = 'none';
                    document.getElementById('codeContainer').className = 'code-empty';
                    document.getElementById('codeContainer').innerHTML = scriptsData.length > 0 
                        ? '// Skript im Baum links auswählen...' 
                        : '<span style="color: #dc3545;">Keine Skripte in diesem Backup gefunden.</span>';
                    
                    form.reset(); 
                } else {
                    alert('Fehler beim Server!');
                    document.getElementById('loader').style.display = 'none';
                }
            };

            xhr.onerror = function() {
                alert('Netzwerkfehler! Server nicht erreichbar.');
                document.getElementById('loader').style.display = 'none';
            };

            xhr.open('POST', '/', true);
            xhr.send(formData);
        }

        function buildTree(data) {
            const root = { children: {} };
            data.forEach((s, idx) => {
                const parts = s.path.split('.');
                let current = root;
                for (let i = 0; i < parts.length - 1; i++) {
                    const p = parts[i];
                    if (!current.children[p]) current.children[p] = { isDir: true, name: p, children: {} };
                    current = current.children[p];
                }
                current.children[parts[parts.length - 1]] = { isDir: false, script: s, index: idx };
            });
            return root;
        }

        function createScriptNode(s, idx) {
            let badgeText = s.type === 'TypeScript' ? 'TS' : (s.type === 'Blockly' ? 'Blockly' : (s.type === 'Rules' ? 'RULES' : 'JS'));
            let div = document.createElement('div');
            div.className = 'script-item';
            div.dataset.index = idx;
            if (cur.index === idx) div.classList.add('active');
            
            div.onclick = function() { selectScript(idx); };
            div.innerHTML = \`
                <div class="script-name" title="\${escapeHTML(s.path)}"><span class="icon-file">📄</span> \${escapeHTML(s.name)}</div>
                <span class="type-badge badge-\${s.type}">\${badgeText}</span>
            \`;
            return div;
        }

        function renderTree(nodes, container, currentPath = '') {
            const keys = Object.keys(nodes).sort((a, b) => {
                const nodeA = nodes[a], nodeB = nodes[b];
                if (nodeA.isDir && !nodeB.isDir) return -1;
                if (!nodeA.isDir && nodeB.isDir) return 1;
                return a.toLowerCase().localeCompare(b.toLowerCase());
            });

            keys.forEach(k => {
                const node = nodes[k];
                const fullPath = currentPath ? currentPath + '.' + k : k;
                
                if (node.isDir) {
                    const folderDiv = document.createElement('div');
                    folderDiv.className = 'tree-folder';
                    folderDiv.dataset.path = fullPath;
                    const isOpen = openFolders.has(fullPath);
                    
                    folderDiv.innerHTML = \`<span class="folder-icon \${isOpen ? 'open' : ''}">▶</span> 📁 \${escapeHTML(node.name)}\`;
                    
                    const childrenContainer = document.createElement('div');
                    childrenContainer.className = 'tree-children';
                    if (isOpen) childrenContainer.classList.add('open');
                    
                    folderDiv.onclick = (e) => {
                        e.stopPropagation();
                        const isNowOpen = childrenContainer.classList.toggle('open');
                        folderDiv.querySelector('.folder-icon').classList.toggle('open');
                        if (isNowOpen) openFolders.add(fullPath);
                        else openFolders.delete(fullPath);
                        
                        if(isAllExpanded) {
                           isAllExpanded = false;
                           document.getElementById('expandToggleBtn').innerHTML = '📂';
                           document.getElementById('expandToggleBtn').title = 'Alle Ordner aufklappen';
                        }
                    };
                    
                    container.appendChild(folderDiv);
                    renderTree(node.children, childrenContainer, fullPath);
                    container.appendChild(childrenContainer);
                } else {
                    const scriptNode = createScriptNode(node.script, node.index);
                    scriptNode.classList.add('tree-script');
                    container.appendChild(scriptNode);
                }
            });
        }

        function renderList() {
            const list = document.getElementById('list');
            list.innerHTML = '';
            const searchVal = document.getElementById('q').value.toLowerCase();
            const toggleBtn = document.getElementById('expandToggleBtn');
            
            const tree = buildTree(scriptsData);
            
            if (searchVal) {
                toggleBtn.style.display = 'none'; 
                const filterNode = (node, path) => {
                    if (!node.isDir) {
                        const matchName = node.script.name.toLowerCase().includes(searchVal);
                        const matchPath = node.script.path.toLowerCase().includes(searchVal);
                        const matchCode = node.script.source && node.script.source.toLowerCase().includes(searchVal);
                        return matchName || matchPath || matchCode;
                    }
                    
                    let hasMatch = false;
                    for (let k in node.children) {
                        const childPath = path ? path + '.' + k : k;
                        if (filterNode(node.children[k], childPath)) {
                            hasMatch = true;
                            openFolders.add(childPath); 
                        } else {
                            delete node.children[k]; 
                        }
                    }
                    return hasMatch;
                };

                for (let k in tree.children) {
                    if (!filterNode(tree.children[k], k)) {
                        delete tree.children[k];
                    } else {
                        openFolders.add(k); 
                    }
                }
            } else {
                toggleBtn.style.display = 'flex'; 
            }

            renderTree(tree.children, list);
        }

        function formatXml(xml) {
            const PADDING = '  ';
            const reg = /(>)\s*(<)(\/*)/g;
            let pad = 0;
            let formatted = '';
            
            xml = xml.replace(reg, '\$1\\n\$2\$3');
            
            xml.split('\\n').forEach(function(node) {
                let indent = 0;
                if (node.match(/.+<\\/\\w[^>]*>\$/)) { indent = 0; } 
                else if (node.match(/^<\\/\\w/)) { if (pad !== 0) pad -= 1; } 
                else if (node.match(/^<\\w[^>]*[^\\/]>.*\$/)) { indent = 1; } 
                else { indent = 0; }
                
                let padding = '';
                for (let i = 0; i < pad; i++) padding += PADDING;
                
                formatted += padding + node + '\\n';
                pad += indent;
            });
            return formatted.trim();
        }

        function formatJson(jsonStr) {
            try { return JSON.stringify(JSON.parse(jsonStr), null, 2); } 
            catch(e) { return jsonStr; }
        }

        function selectScript(idx) {
            cur.index = idx;
            document.querySelectorAll('.script-item').forEach(i => {
                if (parseInt(i.dataset.index) === idx) i.classList.add('active');
                else i.classList.remove('active');
            });
            
            const data = scriptsData[idx];
            let src = data.source || '';
            let xmlStr = null;
            let ruleStr = null;

            if (data.type === 'Blockly') {
                let m = src.match(/\/\/(JTND[A-Za-z0-9+/=%]+)/);
                if (m) {
                    try { xmlStr = formatXml(decodeURIComponent(atob(m[1]))); } 
                    catch(e) {}
                }
            } else if (data.type === 'Rules') {
                let m = src.match(/\/\/({.*"triggers".*})/);
                if (m) {
                    ruleStr = formatJson(m[1]);
                } else {
                    let m_block = src.match(/\/\* const demo = ({[\s\S]*?}); \*\//);
                    if (m_block) { ruleStr = formatJson(m_block[1]); }
                }
            }

            cur.name = data.name;
            cur.type = data.type;
            cur.src = src;
            cur.xml = xmlStr;
            cur.rule = ruleStr;
            
            document.getElementById('actionBar').style.display = 'block';
            document.getElementById('codeContainer').className = 'code-display';
            
            const viewSwitcher = document.getElementById('viewSwitcher'); 
            viewSwitcher.innerHTML = '<button onclick="showView(\\'src\\')" class="btn btn-outline-light" id="btn-src">JS/TS</button>';
            
            if (cur.xml) { viewSwitcher.innerHTML += '<button onclick="showView(\\'xml\\')" class="btn btn-outline-primary" id="btn-xml">BLOCKLY</button>'; }
            if (cur.rule) { viewSwitcher.innerHTML += '<button onclick="showView(\\'rule\\')" class="btn btn-outline-success" id="btn-rule">RULES</button>'; }
            
            showView(cur.xml ? 'xml' : (cur.rule ? 'rule' : 'src'));
        }

        function showView(v) {
            cur.activeView = v; 
            document.querySelectorAll('#viewSwitcher button').forEach(b => b.classList.remove('active'));
            document.getElementById('btn-' + v).classList.add('active'); 
            
            const codeTxt = cur[v] || '';
            const lines = codeTxt.split('\\n');
            const htmlWithLines = lines.map(l => \`<span class="code-line">\${escapeHTML(l) || ' '}</span>\`).join('');
            
            document.getElementById('codeContainer').innerHTML = htmlWithLines;
            
            const dlBtn = document.getElementById('dlBtn'); 
            if (v === 'xml') dlBtn.innerText = 'DL .xml';
            else if (v === 'rule') dlBtn.innerText = 'DL .json';
            else dlBtn.innerText = cur.type === 'TypeScript' ? 'DL .ts' : 'DL .js';
        }

        function copyCode(btn) {
            const txtToCopy = cur[cur.activeView] || '';
            const textArea = document.createElement("textarea"); 
            textArea.value = txtToCopy; 
            document.body.appendChild(textArea); 
            textArea.select();
            
            try { 
                document.execCommand('copy'); 
                btn.innerText = 'Kopiert!'; 
                btn.classList.replace('btn-outline-light', 'btn-success'); 
            } finally { 
                document.body.removeChild(textArea); 
                setTimeout(() => { 
                    btn.innerText = 'Code Kopieren'; 
                    btn.classList.replace('btn-success', 'btn-outline-light'); 
                }, 1500); 
            }
        }

        function downloadActive() {
            const txtToDownload = cur[cur.activeView] || '';
            let ext = cur.activeView === 'xml' ? '.xml' : (cur.activeView === 'rule' ? '.json' : (cur.type === 'TypeScript' ? '.ts' : '.js'));
            const blob = new Blob([txtToDownload], {type: 'text/plain'});
            const a = document.createElement('a'); 
            a.href = URL.createObjectURL(blob); 
            a.download = cur.name + ext; 
            a.click();
        }

        document.getElementById('q').onkeyup = function() {
            renderList();
        };
    </script>
</body>
</html>
EOF

# 6. Autostart Logik oder direkt ausführen
if [[ "$AUTOSTART" =~ ^[Yy]$ ]]; then
    echo "Richte Systemd-Service ein..."
    
    sudo bash -c "cat <<EOF > /etc/systemd/system/$SERVICE_NAME
[Unit]
Description=ioBroker Script Restore Web Interface
After=network.target

[Service]
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/bin/python3 $INSTALL_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

    sudo systemctl daemon-reload
    sudo systemctl enable "$SERVICE_NAME"
    sudo systemctl start "$SERVICE_NAME"
    echo "✅ Setup abgeschlossen! Die App läuft im Hintergrund und startet automatisch."
    echo "🌐 Erreichbar unter: http://$(hostname -I | awk '{print $1}'):$PORT"
else
    if [ -f "/etc/systemd/system/$SERVICE_NAME" ]; then
        echo "🗑️  Entferne bestehenden Autostart-Service..."
        sudo systemctl disable "$SERVICE_NAME" 2>/dev/null
        sudo rm "/etc/systemd/system/$SERVICE_NAME"
        sudo systemctl daemon-reload
        echo "✅ Autostart wurde deaktiviert."
    fi

    echo "✅ Setup abgeschlossen! Starte die App jetzt einmalig im Vordergrund..."
    echo "🌐 Erreichbar unter: http://localhost:$PORT"
    echo "🛑 Beenden mit STRG+C"
    python3 app.py
fi

