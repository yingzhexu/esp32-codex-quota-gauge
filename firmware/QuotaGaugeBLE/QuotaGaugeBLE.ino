/* Codex 额度指针 · ESP32 BLE firmware (ESP32 Arduino Core 3.x)
 *
 * Wiring: SG90 signal (orange) -> GPIO13 (D13), red -> 3V3, brown -> GND.
 * (On this V2363 board VIN carries no USB 5 V, so the servo runs from 3V3.)
 * Optional 470-1000 uF across red/brown if the board resets while moving. Status: on-board LED (GPIO2).
 *
 * Text commands, one per line, over BLE (RX characteristic) or USB serial 115200:
 *   STATUS             report state
 *   P <us>             move to a raw pulse (calibration / centering only)
 *   CAL <us0> <us100>  save pulse for 0% and 100% (either order)
 *   Q <percent>        show remaining quota 0..100 (needs CAL first)
 *   T <percent>        test position 0..100 (needs CAL; not counted as quota data)
 *   SPEED <deg/s>      servo speed 10..400, saved (default 90; SG90 max ~400)
 *   STALE              mark data as stale (LED blinks slowly)
 *   OFF                stop driving the servo
 * Replies ("OK ..." / "ERR ..." / "STATUS ...") go to serial and BLE notify.
 *
 * The servo is released (no pulses) shortly after reaching its target, so it
 * does not buzz or keep pushing. The rack is light and stays where it is.
 * Starts uncalibrated: Q is refused until CAL is saved. Never calibrate
 * against the mechanical end stops; 0%/100% marks have only ~1.2 mm margin.
 */
#include <Arduino.h>
#include <Preferences.h>
#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLE2902.h>
#include <math.h>

constexpr uint8_t SERVO_PIN = 13;
constexpr uint8_t LED_PIN = 2;
constexpr int PWM_BITS = 16;
constexpr int CAL_MIN_US = 500;
constexpr int CAL_MAX_US = 2500;
constexpr float US_PER_DEG = 2000.0f / 180.0f;
constexpr float DEFAULT_SPEED_DPS = 90.0f;  // full 0-100% stroke (118.5 deg) in ~1.3 s
constexpr uint32_t HOLD_MS = 800;           // keep pulsing after arrival
constexpr uint32_t STALE_MS = 10UL * 60 * 1000;

#define DEVICE_NAME  "CodexGauge"
#define SERVICE_UUID "6e400001-c0de-4a11-9a5e-000000000001"
#define RX_UUID      "6e400002-c0de-4a11-9a5e-000000000001"
#define TX_UUID      "6e400003-c0de-4a11-9a5e-000000000001"

Preferences prefs;
bool calibrated = false, pwmOn = false, hasData = false, bleConnected = false;
int emptyUs = 1000, fullUs = 2000;
float currentUs = 1500, targetUs = 1500, lastPercent = NAN, speedDps = DEFAULT_SPEED_DPS;
uint32_t lastDataMs = 0, lastStepMs = 0, arrivedMs = 0;
bool arrived = true;

BLECharacteristic *txChar = nullptr;
QueueHandle_t bleLines;              // BLE callback -> loop(), 64-byte lines
struct Line { char s[64]; };

void reply(const char *fmt, ...) {
  char buf[120];
  va_list ap; va_start(ap, fmt); vsnprintf(buf, sizeof(buf), fmt, ap); va_end(ap);
  Serial.println(buf);
  if (bleConnected && txChar) { txChar->setValue((uint8_t *)buf, strlen(buf)); txChar->notify(); }
}

void writePulse(float us) {
  ledcWrite(SERVO_PIN, (uint32_t)lroundf(us * 65535.0f / 20000.0f));
}
bool startPwm() {
  if (!pwmOn) {
    if (!ledcAttach(SERVO_PIN, 50, PWM_BITS)) { reply("ERR PWM_ATTACH"); return false; }
    pwmOn = true;
    writePulse(currentUs);
  }
  return true;
}
void releaseServo() {
  if (pwmOn) { ledcWrite(SERVO_PIN, 0); ledcDetach(SERVO_PIN); pwmOn = false; }
  pinMode(SERVO_PIN, OUTPUT); digitalWrite(SERVO_PIN, LOW);
}
void moveTo(float us) {
  if (!startPwm()) return;
  targetUs = us; arrived = false;
}

bool fresh() { return hasData && (uint32_t)(millis() - lastDataMs) < STALE_MS; }

void status() {
  reply("STATUS cal=%d fresh=%d empty_us=%d full_us=%d pct=%.1f us=%.0f speed=%.0f",
        calibrated, fresh(), emptyUs, fullUs, lastPercent, currentUs, speedDps);
}

void handle(const char *line) {
  float percent; int a, b; char extra;
  if (!strcmp(line, "STATUS")) { status(); return; }
  if (!strcmp(line, "STALE")) { hasData = false; reply("OK STALE"); return; }
  if (!strcmp(line, "OFF")) { releaseServo(); arrived = true; reply("OK OFF"); return; }
  if (sscanf(line, "CAL %d %d %c", &a, &b, &extra) == 2) {
    if (a < CAL_MIN_US || a > CAL_MAX_US || b < CAL_MIN_US || b > CAL_MAX_US || abs(a - b) < 200) {
      reply("ERR CAL_RANGE"); return;
    }
    emptyUs = a; fullUs = b; calibrated = true;
    prefs.putInt("empty", a); prefs.putInt("full", b); prefs.putBool("cal", true);
    reply("OK CAL %d %d", a, b); return;
  }
  if (sscanf(line, "P %d %c", &a, &extra) == 1) {
    if (a < CAL_MIN_US || a > CAL_MAX_US) { reply("ERR P_RANGE"); return; }
    moveTo(a); hasData = false; reply("OK P %d", a); return;
  }
  if (sscanf(line, "SPEED %f %c", &percent, &extra) == 1) {
    if (!isfinite(percent) || percent < 10 || percent > 400) { reply("ERR SPEED_RANGE"); return; }
    speedDps = percent; prefs.putFloat("speed", speedDps);
    reply("OK SPEED %.0f", speedDps); return;
  }
  if (sscanf(line, "T %f %c", &percent, &extra) == 1) {
    if (!isfinite(percent) || percent < 0 || percent > 100) { reply("ERR T_RANGE"); return; }
    if (!calibrated) { reply("ERR NOT_CALIBRATED"); return; }
    moveTo(emptyUs + (fullUs - emptyUs) * percent / 100.0f);
    reply("OK T %.1f", percent); return;
  }
  if (sscanf(line, "Q %f %c", &percent, &extra) == 1) {
    if (!isfinite(percent) || percent < 0 || percent > 100) { reply("ERR Q_RANGE"); return; }
    if (!calibrated) { reply("ERR NOT_CALIBRATED"); return; }
    moveTo(emptyUs + (fullUs - emptyUs) * percent / 100.0f);
    lastPercent = percent; lastDataMs = millis(); hasData = true;
    reply("OK Q %.1f", percent); return;
  }
  reply("ERR COMMAND");
}

class ServerCb : public BLEServerCallbacks {
  void onConnect(BLEServer *) override { bleConnected = true; }
  void onDisconnect(BLEServer *s) override {
    bleConnected = false;
    s->getAdvertising()->start();   // accept the next connection
  }
};
class RxCb : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic *c) override {
    String v = c->getValue();
    Line l{};
    size_t n = 0;
    for (size_t i = 0; i < v.length() && n < sizeof(l.s) - 1; i++) {
      char ch = v[i];
      if (ch == '\r') continue;
      if (ch == '\n') { l.s[n] = 0; if (n) xQueueSend(bleLines, &l, 0); n = 0; continue; }
      l.s[n++] = ch;
    }
    if (n) { l.s[n] = 0; xQueueSend(bleLines, &l, 0); }
  }
};

void setupBle() {
  bleLines = xQueueCreate(8, sizeof(Line));
  BLEDevice::init(DEVICE_NAME);
  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ServerCb());
  BLEService *svc = server->createService(SERVICE_UUID);
  BLECharacteristic *rx = svc->createCharacteristic(RX_UUID,
      BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_WRITE_NR);
  rx->setCallbacks(new RxCb());
  txChar = svc->createCharacteristic(TX_UUID,
      BLECharacteristic::PROPERTY_NOTIFY | BLECharacteristic::PROPERTY_READ);
  txChar->addDescriptor(new BLE2902());
  svc->start();
  BLEAdvertising *adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->setScanResponse(true);
  BLEDevice::startAdvertising();
}

void setup() {
  pinMode(LED_PIN, OUTPUT); digitalWrite(LED_PIN, LOW);
  releaseServo();
  Serial.begin(115200);
  prefs.begin("quota-gauge", false);
  emptyUs = prefs.getInt("empty", 1000); fullUs = prefs.getInt("full", 2000);
  speedDps = constrain(prefs.getFloat("speed", DEFAULT_SPEED_DPS), 10.0f, 400.0f);
  calibrated = prefs.getBool("cal", false) && emptyUs >= CAL_MIN_US && emptyUs <= CAL_MAX_US
            && fullUs >= CAL_MIN_US && fullUs <= CAL_MAX_US && abs(emptyUs - fullUs) >= 200;
  // Unknown position after power-up: assume centre; the first move slews from there.
  currentUs = targetUs = 1500;
  setupBle();
  Serial.println("READY CODEX_GAUGE_BLE V4");
  status();
}

char serBuf[64]; size_t serLen = 0; bool serOverflow = false;

void loop() {
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (ch == '\r') continue;
    if (ch == '\n') {
      if (serOverflow) reply("ERR LINE_TOO_LONG");
      else if (serLen) { serBuf[serLen] = 0; handle(serBuf); }
      serLen = 0; serOverflow = false;
    } else if (serLen < sizeof(serBuf) - 1 && !serOverflow) serBuf[serLen++] = ch;
    else serOverflow = true;
  }
  Line l;
  while (xQueueReceive(bleLines, &l, 0) == pdTRUE) handle(l.s);

  const uint32_t now = millis();
  if (pwmOn && (uint32_t)(now - lastStepMs) >= 20) {
    lastStepMs = now;
    const float delta = targetUs - currentUs;
    const float step = speedDps * US_PER_DEG * 0.02f;   // per 20 ms frame
    currentUs += constrain(delta, -step, step);
    writePulse(currentUs);
    if (fabsf(targetUs - currentUs) < 0.5f) {
      if (!arrived) { arrived = true; arrivedMs = now; }
      else if ((uint32_t)(now - arrivedMs) >= HOLD_MS) releaseServo();
    }
  }
  // LED: on = fresh data; slow blink = stale; fast blink = not calibrated.
  bool led = !calibrated ? (now / 125) % 2 : (fresh() ? true : (now / 1000) % 2);
  digitalWrite(LED_PIN, led);
  delay(2);
}
