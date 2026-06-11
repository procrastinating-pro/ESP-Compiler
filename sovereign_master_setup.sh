#!/bin/bash

# ==============================================================================
# SOVEREIGN IDE & HYDROPONICS SMART CONTROLLER - MASTER INSTALLER (v4.0)
# ==============================================================================

BASE_DIR="$HOME/local-esp-ide"
WORK_DIR="$BASE_DIR/workspaces/hydroponika_system"
BACKEND_DIR="$BASE_DIR/backend"
FRONTEND_DIR="$BASE_DIR/frontend"

echo "=================================================="
echo " Inicjalizacja Pełnej Automatyki z Auto-Flashem "
echo "=================================================="

rm -rf "$BASE_DIR"
mkdir -p "$BACKEND_DIR" "$FRONTEND_DIR" "$WORK_DIR/main"

# 1. PLIKI PROJEKTOWE
cat << 'EOF' > "$WORK_DIR/CMakeLists.txt"
cmake_minimum_required(VERSION 3.16)
include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(hydroponika_system)
EOF

cat << 'EOF' > "$WORK_DIR/main/CMakeLists.txt"
idf_component_register(SRCS "main.c" INCLUDE_DIRS ".")
EOF

cat << 'EOF' > "$WORK_DIR/main/idf_component.yml"
dependencies:
  espressif/cjson: "*"
EOF

# 2. GŁÓWNY KOD W C (Odwrócona logika, Okna czasowe, Polska Strefa Czasowa)
cat << 'EOF' > "$WORK_DIR/main/main.c"
#include <string.h>
#include <sys/time.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "driver/gpio.h"
#include "esp_wifi.h"
#include "esp_log.h"
#include "nvs_flash.h"
#include "esp_http_server.h"
#include "cJSON.h"

static const char *TAG = "HYDRO_CORE";

// Definicje sprzętowe dla przekaźników Active-Low
#define RELAY_ON  0
#define RELAY_OFF 1

typedef struct {
    int pin;
    int mode;          // 0 = Ręczny, 1 = Automatyka czasowa
    int start_h;       // Godzina rozpoczęcia cyklu (0-23)
    int end_h;         // Godzina zakończenia cyklu (0-23)
    int time_on;       // Czas działania [sekundy]
    int time_off;      // Czas uśpienia [sekundy]
    int manual_state;  // 0 = Włączony, 1 = Wyłączony
    uint32_t last_toggle_tick;
    bool is_active;    // Wewnętrzna flaga stanu (true = pompa pracuje)
} ChannelConfig;

const int PINS[16] = {4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 21};
ChannelConfig relays[16];
int active_channels = 0;

void init_relay_gpio(int pin) {
    gpio_config_t io_conf = {
        .intr_type = GPIO_INTR_DISABLE,
        .mode = GPIO_MODE_OUTPUT,
        .pin_bit_mask = (1ULL << pin),
        .pull_down_en = 0,
        .pull_up_en = 0
    };
    gpio_config(&io_conf);
}

// Zaktualizowany interfejs WWW dodający kontrolę przedziałów czasowych i odpowiednie nazewnictwo stanów
const char* html_page = "<!DOCTYPE html><html lang='pl'><head><meta charset='UTF-8'>"
"<title>Hydro-Sterownik S3</title>"
"<style>body{background:#0a0a0c;color:#0f0;font-family:monospace;padding:20px;max-width:900px;margin:0 auto;}"
"input,select,button{background:#111;color:#0f0;border:1px solid #0f0;padding:12px;margin:8px 0;width:100%;box-sizing:border-box;font-family:inherit;font-size:14px;}"
"button{cursor:pointer;font-weight:bold;text-transform:uppercase;}button:hover{background:#0f0;color:#000;}"
".panel{border:1px solid #333;border-left:4px solid #0f0;padding:15px;margin-bottom:20px;background:#0d0d12;}"
".pin-info{color:#00d8ff;font-weight:bold;}.hide{display:none;}.grid{display:grid;grid-template-columns:1fr 1fr;gap:10px;}</style></head><body>"
"<h2>[SYS] HYDRO-STEROWNIK :: ACTIVE-LOW PRO</h2>"
"<div class='panel'><h3>1. Synchronizacja Zegara (Polska Strefa Czasowa)</h3>"
"<input type='datetime-local' id='timeInput'><button onclick='syncTime()'>USTAW CZAS SYSTEMOWY</button></div>"
"<div class='panel'><h3>2. Konfiguracja Sprzętowa</h3>"
"<select id='relayCount' onchange='renderRelays()'>"
"<option value='0'>Wybierz ilość obsługiwanych kanałów...</option>"
"<option value='1'>Moduł 1-kanałowy</option>"
"<option value='2'>Moduł 2-kanałowy</option>"
"<option value='4'>Moduł 4-kanałowy</option>"
"<option value='8'>Moduł 8-kanałowy</option>"
"<option value='16'>Moduł 16-kanałowy</option></select></div>"
"<div id='relaysContainer'></div>"
"<button id='saveBtn' onclick='saveConfig()' style='display:none;border-color:#ff003c;color:#ff003c;'>ZAPISZ I WGRAJ DO PAMIĘCI</button>"
"<script>"
"const PINS = [4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 21];"
"function syncTime(){const d=document.getElementById('timeInput').value;"
"if(!d){alert('Wybierz datę!');return;}"
"fetch('/api/time',{method:'POST',body:Math.floor(new Date(d).getTime()/1000).toString()}).then(()=>alert('Czas zaktualizowany!'));}"
"function renderRelays(){"
"const count=parseInt(document.getElementById('relayCount').value);"
"const c=document.getElementById('relaysContainer');c.innerHTML='';"
"if(count===0){document.getElementById('saveBtn').style.display='none';return;}"
"let h='';"
"for(let i=0;i<count;i++){"
"h+=`<div class='panel'><h4>KANAŁ ${i+1} <span class='pin-info'>[Fizyczny PIN GPIO ${PINS[i]}]</span></h4>"
"<label>Tryb pracy kanału:</label><select id='mode_${i}' onchange='toggleMode(${i})'>"
"<option value='1'>Automatyka Czasowa (Interwały)</option>"
"<option value='0'>Sterowanie Ręczne (Sztywne)</option></select>"
"<div id='time_box_${i}'>"
"<div class='grid'><div><label>Aktywny OD (godzina 0-23):</label><input type='number' id='start_h_${i}' value='6' min='0' max='23'></div>"
"<div><label>Aktywny DO (godzina 0-23):</label><input type='number' id='end_h_${i}' value='22' min='0' max='23'></div></div>"
"<div class='grid'><div><label>Praca [ON] (sekundy):</label><input type='number' id='on_${i}' value='10'></div>"
"<div><label>Pauza [OFF] (sekundy):</label><input type='number' id='off_${i}' value='30'></div></div></div>"
"<div id='manual_box_${i}' class='hide'>"
"<label>Wymuś fizyczny stan przekaźnika:</label><select id='state_${i}'>"
"<option value='1'>WYŁĄCZONY (Stan HIGH / 3.3V)</option>"
"<option value='0'>WŁĄCZONY (Stan LOW / 0V)</option></select></div></div>`;"
"}c.innerHTML=h;document.getElementById('saveBtn').style.display='block';}"
"function toggleMode(i){"
"const m=document.getElementById(`mode_${i}`).value;"
"if(m==='1'){document.getElementById(`time_box_${i}`).classList.remove('hide');document.getElementById(`manual_box_${i}`).classList.add('hide');}"
"else{document.getElementById(`time_box_${i}`).classList.add('hide');document.getElementById(`manual_box_${i}`).classList.remove('hide');}}"
"function saveConfig(){"
"const count=parseInt(document.getElementById('relayCount').value);"
"let cfg={active:count,channels:[]};"
"for(let i=0;i<count;i++){"
"const m=parseInt(document.getElementById(`mode_${i}`).value);"
"cfg.channels.push({pin:PINS[i],mode:m,start:parseInt(document.getElementById(`start_h_${i}`).value),end:parseInt(document.getElementById(`end_h_${i}`).value),"
"on:parseInt(document.getElementById(`on_${i}`).value),off:parseInt(document.getElementById(`off_${i}`).value),state:parseInt(document.getElementById(`state_${i}`).value)});"
"}fetch('/api/config',{method:'POST',body:JSON.stringify(cfg)}).then(()=>alert('Nowa konfiguracja została zastosowana!'));}"
"</script></body></html>";

static esp_err_t get_handler(httpd_req_t *req) {
    httpd_resp_send(req, html_page, HTTPD_RESP_USE_STRLEN);
    return ESP_OK;
}

static esp_err_t post_time_handler(httpd_req_t *req) {
    char buf[32];
    int ret = httpd_req_recv(req, buf, sizeof(buf)-1);
    if (ret > 0) {
        buf[ret] = '\0';
        struct timeval tv = { .tv_sec = atol(buf), .tv_usec = 0 };
        settimeofday(&tv, NULL);
        ESP_LOGI(TAG, "[RTC] Otrzymano czas UNIX. Zegar zsynchronizowany.");
    }
    return httpd_resp_send_chunk(req, NULL, 0);
}

static esp_err_t post_config_handler(httpd_req_t *req) {
    char buf[2048];
    int ret = httpd_req_recv(req, buf, sizeof(buf)-1);
    if (ret > 0) {
        buf[ret] = '\0';
        cJSON *json = cJSON_Parse(buf);
        if (json != NULL) {
            cJSON *active = cJSON_GetObjectItem(json, "active");
            if (cJSON_IsNumber(active)) {
                active_channels = active->valueint;
                cJSON *arr = cJSON_GetObjectItem(json, "channels");
                
                for (int i = 0; i < active_channels && i < 16; i++) {
                    cJSON *item = cJSON_GetArrayItem(arr, i);
                    if (item) {
                        relays[i].pin = cJSON_GetObjectItem(item, "pin")->valueint;
                        relays[i].mode = cJSON_GetObjectItem(item, "mode")->valueint;
                        relays[i].start_h = cJSON_GetObjectItem(item, "start")->valueint;
                        relays[i].end_h = cJSON_GetObjectItem(item, "end")->valueint;
                        relays[i].time_on = cJSON_GetObjectItem(item, "on")->valueint;
                        relays[i].time_off = cJSON_GetObjectItem(item, "off")->valueint;
                        relays[i].manual_state = cJSON_GetObjectItem(item, "state")->valueint;
                        relays[i].last_toggle_tick = xTaskGetTickCount();
                        relays[i].is_active = false;
                        
                        init_relay_gpio(relays[i].pin);
                        
                        if (relays[i].mode == 0) {
                            gpio_set_level(relays[i].pin, relays[i].manual_state);
                            ESP_LOGW(TAG, "[RĘCZNY] Kanał %d (GPIO %d) ustawiony na twardo. Napięcie: %s", i+1, relays[i].pin, relays[i].manual_state == RELAY_ON ? "0V (ON)" : "3.3V (OFF)");
                        } else {
                            gpio_set_level(relays[i].pin, RELAY_OFF);
                            ESP_LOGI(TAG, "[AUTO] Kanał %d (GPIO %d) uzbrojony. Okno pracy: %d:00 - %d:00", i+1, relays[i].pin, relays[i].start_h, relays[i].end_h);
                        }
                    }
                }
            }
            cJSON_Delete(json);
        }
    }
    return httpd_resp_send_chunk(req, NULL, 0);
}

// Główny wątek logiczny uwzględniający Active-Low i ramy czasowe
void watering_task(void *pvParameter) {
    while(1) {
        time_t now; struct tm timeinfo;
        time(&now); localtime_r(&now, &timeinfo);
        uint32_t current_ticks = xTaskGetTickCount();

        if (timeinfo.tm_year > (2020 - 1900)) {
            // ESP_LOGI(TAG, "[TICK] %02d:%02d:%02d | Silnik sprawdza %d kanałów...", timeinfo.tm_hour, timeinfo.tm_min, timeinfo.tm_sec, active_channels);
            
            for (int i = 0; i < active_channels; i++) {
                if (relays[i].mode == 0) {
                    // Tryb ręczny omija logikę czasu
                    gpio_set_level(relays[i].pin, relays[i].manual_state);
                    continue;
                }
                
                // Sprawdzenie, czy znajdujemy się w oknie operacyjnym dla tego kanału
                bool in_window = false;
                int h = timeinfo.tm_hour;
                int sh = relays[i].start_h;
                int eh = relays[i].end_h;
                
                if (sh == eh) {
                    in_window = true; // Praca 24/7
                } else if (sh < eh) {
                    in_window = (h >= sh && h < eh); // np. 06:00 do 22:00
                } else {
                    in_window = (h >= sh || h < eh); // Praca przez noc, np. 22:00 do 06:00
                }

                if (!in_window) {
                    // Jeśli poza oknem czasowym -> twarde odcięcie (HIGH)
                    if (relays[i].is_active) {
                        relays[i].is_active = false;
                        gpio_set_level(relays[i].pin, RELAY_OFF);
                        ESP_LOGE(TAG, "[HARMONOGRAM] Kanał %d -> Koniec okna czasowego. Zasilanie odcięte.", i+1);
                    }
                    continue;
                }

                // Logika czasówek (Tylko w trakcie trwania okna operacyjnego)
                uint32_t elapsed_sec = (current_ticks - relays[i].last_toggle_tick) * portTICK_PERIOD_MS / 1000;
                
                if (relays[i].is_active) { // Aktualnie podlewa
                    if (elapsed_sec >= relays[i].time_on) {
                        relays[i].is_active = false;
                        relays[i].last_toggle_tick = current_ticks;
                        gpio_set_level(relays[i].pin, RELAY_OFF); // Przekaż 3.3V (Wyłącz układ izolacji)
                        ESP_LOGW(TAG, "[PRZEKAŹNIK] Kanał %d (GPIO %d) -> OFF (Cykl wyłączony)", i+1, relays[i].pin);
                    }
                } else { // Aktualnie czeka
                    if (elapsed_sec >= relays[i].time_off) {
                        relays[i].is_active = true;
                        relays[i].last_toggle_tick = current_ticks;
                        gpio_set_level(relays[i].pin, RELAY_ON);  // Przekaż 0V (Załącz układ izolacji)
                        ESP_LOGE(TAG, "[PRZEKAŹNIK] Kanał %d (GPIO %d) -> ON  (Cykl aktywny)", i+1, relays[i].pin);
                    }
                }
            }
        } else {
            ESP_LOGW(TAG, "[BŁĄD RTC] Zegar układu wciąż nie został zsynchronizowany!");
        }
        vTaskDelay(1000 / portTICK_PERIOD_MS); // Próbkowanie co 1 sekundę
    }
}

void app_main(void) {
    // Ustawienie polskiej strefy czasowej (Czas letni/zimowy automatycznie)
    setenv("TZ", "CET-1CEST,M3.5.0/2,M10.5.0/3", 1);
    tzset();

    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
      ESP_ERROR_CHECK(nvs_flash_erase()); ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    esp_netif_init();
    esp_event_loop_create_default();
    esp_netif_create_default_wifi_ap();
    
    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);
    wifi_config_t wifi_config = { .ap = { .ssid = "Hydro-Sterownik", .password = "haker1234", .authmode = WIFI_AUTH_WPA2_PSK, .max_connection = 4 } };
    esp_wifi_set_mode(WIFI_MODE_AP);
    esp_wifi_set_config(WIFI_IF_AP, &wifi_config);
    esp_wifi_start();

    httpd_config_t h_cfg = HTTPD_DEFAULT_CONFIG();
    h_cfg.max_uri_handlers = 16;
    httpd_handle_t server = NULL;
    if (httpd_start(&server, &h_cfg) == ESP_OK) {
        httpd_uri_t uri_g = { .uri = "/", .method = HTTP_GET, .handler = get_handler };
        httpd_uri_t uri_t = { .uri = "/api/time", .method = HTTP_POST, .handler = post_time_handler };
        httpd_uri_t uri_c = { .uri = "/api/config", .method = HTTP_POST, .handler = post_config_handler };
        httpd_register_uri_handler(server, &uri_g);
        httpd_register_uri_handler(server, &uri_t);
        httpd_register_uri_handler(server, &uri_c);
    }

    xTaskCreatePinnedToCore(watering_task, "watering_task", 4096, NULL, 5, NULL, 1);
}
EOF

# 3. WARSTWA BACKENDU (FastAPI + Zintegrowany Flash)
echo "[*] Inicjalizacja Demona z funkcją Auto-Flash..."
cd "$BACKEND_DIR" || exit
python3 -m venv venv
source venv/bin/activate
pip install fastapi uvicorn websockets > /dev/null 2>&1

cat << 'EOF' > "$BACKEND_DIR/main.py"
from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware
import asyncio, os, shlex

app = FastAPI()
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

@app.websocket("/api/build")
async def build_stream(websocket: WebSocket, target: str = "esp32s3"):
    await websocket.accept()
    await websocket.send_json({"status": "info", "message": f"Kompilacja i wgrywanie na układ: {target.upper()} (port: /dev/ttyACM0)..."})
    
    project_path = os.path.abspath("../workspaces/hydroponika_system")
    idf_export = os.path.abspath(os.path.expanduser("~/esp/esp-idf/export.sh"))
    
    # Dodany parametr 'flash' na końcu łańcucha budowania
    command = f"source {shlex.quote(idf_export)} && idf.py set-target {shlex.quote(target)} && stdbuf -oL idf.py build flash -p /dev/ttyACM0"
    
    try:
        process = await asyncio.create_subprocess_shell(
            command, cwd=project_path, executable='/bin/bash',
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
        )
        while True:
            line = await process.stdout.readline()
            if not line: break
            await websocket.send_json({"status": "log", "payload": line.decode('utf-8', 'replace').strip()})
        
        code = await process.wait()
        if code == 0:
            await websocket.send_json({"status": "success", "message": "Zbudowano i pomyślnie wgrano wsad do układu!"})
        else:
            await websocket.send_json({"status": "error", "message": f"Błąd wgrywania (Kod: {code}). Pamiętaj o przycisku BOOT na płytce!" })
    except Exception as e:
        await websocket.send_json({"status": "error", "message": str(e)})
    finally:
        await websocket.close()
EOF
deactivate

# 4. WARSTWA FRONTENDU IDE
echo "[*] Generowanie interfejsu graficznego IDE..."
cat << 'EOF' > "$FRONTEND_DIR/index.html"
<!DOCTYPE html>
<html lang="pl">
<head>
    <meta charset="UTF-8"><title>Sovereign ESP32 IDE</title>
    <style>
        body { background: #0a0a0c; color: #00ff00; font-family: monospace; padding: 20px; }
        .controls { background: #111; padding: 15px; border-left: 4px solid #00ff00; margin-bottom: 20px; display: flex; gap: 15px; align-items: center; }
        select, button { background: #000; color: #00ff00; border: 1px solid #00ff00; padding: 10px; cursor: pointer; text-transform: uppercase; font-weight: bold;}
        button:hover { background: #00ff00; color: #000; }
        button:disabled { border-color: #555; color: #555; cursor: not-allowed; }
        #terminal { background: #000; padding: 15px; border: 1px solid #333; height: 60vh; overflow-y: auto; line-height: 1.4; }
        .log-error { color: #ff003c; } .log-info { color: #888; } .log-success { color: #00ff00; font-weight:bold; }
    </style>
</head>
<body>
    <h1>[SYS] BARE METAL IDE :: DUAL-MODE CONTROLLER</h1>
    <div class="controls">
        <select id="chipSelect"><option value="esp32s3" selected>Target: ESP32-S3</option></select>
        <button id="buildBtn" style="border-color:#ff003c; color:#ff003c;">[EXEC] KOMPILUJ I WGRAJ DO ESP32</button>
        <span style="color:#888; font-size: 12px; margin-left: auto;">Terminal używaj tylko do: idf.py monitor</span>
    </div>
    <div id="terminal"><span class="log-info">System gotowy. Upewnij się, że kabel USB jest podpięty (/dev/ttyACM0).<br></span></div>
    <script>
        const terminal = document.getElementById('terminal');
        const buildBtn = document.getElementById('buildBtn');
        function log(msg, type='info') {
            terminal.innerHTML += `<span class="${type === 'error' ? 'log-error' : type === 'success' ? 'log-success' : type === 'info' ? 'log-info' : ''}">${msg}</span><br>`;
            terminal.scrollTop = terminal.scrollHeight;
        }
        buildBtn.onclick = () => {
            buildBtn.disabled = true;
            log(`\n> Inicjalizacja cyklu: Build -> Flash...`, 'info');
            log(`> Jeśli układ nie posiada auto-resetu, wciśnij i przytrzymaj przycisk BOOT na płytce TERAZ!`, 'error');
            const ws = new WebSocket(`ws://127.0.0.1:8000/api/build?target=${document.getElementById('chipSelect').value}`);
            ws.onmessage = e => {
                const d = JSON.parse(e.data);
                if(d.status === 'log') log(d.payload, 'build');
                else log(`[${d.status.toUpperCase()}] ${d.message || d.payload}`, d.status);
            };
            ws.onclose = () => { buildBtn.disabled = false; };
        };
    </script>
</body></html>
EOF

# 5. SKRYPT URUCHOMIENIOWY
cat << 'EOF' > "$BASE_DIR/run_ide.sh"
#!/bin/bash
cleanup() { kill $BACKEND_PID $FRONTEND_PID 2>/dev/null; exit 0; }
trap cleanup SIGINT SIGTERM
cd "$HOME/local-esp-ide/backend" && source venv/bin/activate && uvicorn main:app --host 127.0.0.1 --port 8000 > /dev/null 2>&1 & BACKEND_PID=$!
cd "$HOME/local-esp-ide/frontend" && python3 -m http.server 3000 > /dev/null 2>&1 & FRONTEND_PID=$!
echo "=================================================="
echo " IDE AKTYWNE: http://localhost:3000"
echo "=================================================="
wait
EOF
chmod +x "$BASE_DIR/run_ide.sh"

echo "[+] Gotowe! Uruchom komendą: ~/local-esp-ide/run_ide.sh"
