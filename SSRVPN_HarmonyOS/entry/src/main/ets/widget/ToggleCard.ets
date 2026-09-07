/**
 * SSRVPN 服务卡片（2x2）：状态 + 一键连接/断开
 * 移植自 upstream VpnTileService 的快捷开关语义。
 * 通过 postCardAction 向 UIAbility 发送 router 事件，由 HomePage 轮询 card_toggle_requested 执行。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct ToggleCard {
  @State stateText: string = '未连接';

  build() {
    Column({ space: 6 }) {
      Text('SSRVPN')
        .fontSize(12)
        .fontColor('#A4ACB8')
      Text(this.stateText)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor('#F4F6F8')
      Button('连接 / 断开')
        .fontSize(12)
        .fontColor(Color.White)
        .backgroundColor('#2F6BFF')
        .borderRadius(12)
        .onClick(() => {
          postCardAction(this, {
            'action': 'router',
            'abilityName': 'EntryAbility',
            'params': { 'auto_connect': '1' }
          });
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#101114')
    .borderRadius(16)
  }
}
