/* SG90 舵机测试（USB 串口 115200，每条命令以回车结束）
 * 接线：信号 D13，红 VIN，棕 GND
 *   0..180     转到该角度（500-2500 us 对应 0-180 度）
 *   u1500      直接给脉宽（微秒，500-2500）
 *   c          回中 90 度
 *   s          慢速来回扫一次 30 -> 150 -> 90（正好是指针工作范围）
 *   o          停止输出，舵机放松
 * 未装进机构时测试；装进齿条后不要用接近 0 或 180 的角度，会顶到止挡。
 */
#include <Arduino.h>

constexpr uint8_t SERVO_PIN = 13;
constexpr int PWM_BITS = 16;
bool on = false;
float currentUs = 1500;

void writeUs(float us) {
  if (!on) { ledcAttach(SERVO_PIN, 50, PWM_BITS); on = true; }
  ledcWrite(SERVO_PIN, (uint32_t)lroundf(us * 65535.0f / 20000.0f));
  currentUs = us;
}
void moveSmooth(float target) {          // ~0.5 deg per 20 ms
  if (!on) writeUs(currentUs);
  while (fabsf(target - currentUs) > 0.5f) {
    writeUs(currentUs + constrain(target - currentUs, -6.0f, 6.0f));
    delay(20);
  }
  writeUs(target);
}
float degToUs(float d) { return 500 + d * 2000.0f / 180.0f; }

void setup() {
  Serial.begin(115200);
  delay(300);
  Serial.println("READY SERVO_TEST D13  命令: 0-180 角度 | u1500 脉宽 | c 回中 | s 扫描 | o 放松");
}

void loop() {
  if (!Serial.available()) return;
  String cmd = Serial.readStringUntil('\n'); cmd.trim();
  if (!cmd.length()) return;
  char k = cmd[0];
  if (k == 'c') { moveSmooth(degToUs(90)); Serial.println("OK 90 deg (1500 us)"); }
  else if (k == 'o') { ledcWrite(SERVO_PIN, 0); ledcDetach(SERVO_PIN); on = false; Serial.println("OK off"); }
  else if (k == 's') {
    for (float d : {30.f, 150.f, 90.f}) { moveSmooth(degToUs(d)); Serial.printf("at %.0f deg\n", d); delay(400); }
    Serial.println("OK sweep");
  }
  else if (k == 'u') {
    int us = cmd.substring(1).toInt();
    if (us < 500 || us > 2500) { Serial.println("ERR 500-2500"); return; }
    moveSmooth(us); Serial.printf("OK %d us (%.1f deg)\n", us, (us - 500) * 180.0f / 2000.0f);
  }
  else if (isDigit(k)) {
    float d = cmd.toFloat();
    if (d < 0 || d > 180) { Serial.println("ERR 0-180"); return; }
    moveSmooth(degToUs(d)); Serial.printf("OK %.1f deg (%.0f us)\n", d, degToUs(d));
  }
  else Serial.println("ERR 命令: 0-180 | u1500 | c | s | o");
}
