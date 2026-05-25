# lmi-power

`lmi-power` 是 Xiaomi lmi 主线 Linux rootfs 支持层里的电源策略项目，按用户要求由 AI 编写。

它使用内核标准 `power_supply` sysfs 接口管理长期插电场景：

- `charge_behaviour=auto|inhibit-charge`
- `input_current_limit` 目标输入电流
- `current_max` 实际/settled 输入电流

默认策略：75% 停充、70% 恢复、55°C 热停充、50°C 热恢复、10°C 冷停充、15°C 冷恢复；充电目标 700mA，停充保持目标 1000mA。

这是一套保守限充和温度保护策略，不是硬件旁路供电，也不承诺电池完全无老化。

## 命令

```sh
lmi-power status
lmi-power policy
lmi-power charge auto|inhibit
lmi-power limit 700mA
lmi-power backlight status|on|off|toggle|brightness <value>
lmi-power keys status
lmi-power keys set power toggle-backlight
lmi-power keys set volume-up brightness-up
lmi-power keys set volume-down brightness-down
lmi-power keys actions
lmi-power validate
```

默认按键动作在 `/etc/lmi-power/keys.conf`：电源键切换背光，音量上调亮，音量下调暗。可选动作包括 `toggle-backlight`、`backlight-on`、`backlight-off`、`brightness-up`、`brightness-down` 和 `none`。

## 服务

- `lmi-powerd.service`：电池限充、恢复、温度保护和输入限流策略。
- `lmi-power-keysd.service`：统一接管电源键和音量键，按 `/etc/lmi-power/keys.conf` 执行背光/亮度动作。
