/**
 * SSRVPN 服务卡片（2x2）：状态 + 一键连接/断开
 * 移植自 upstream VpnTileService 的快捷开关语义。
 *
 * 点击走 postCardAction 'message' → EntryFormAbility.onFormEvent（FormExtension
 * 后台回调, 不拉起任何页面）→ VpnQuickStart 切换连接 → formProvider 回写卡片状态。
 */
let storage = new LocalStorage();

@Entry(storage)
@Component
struct ToggleCard {
  @LocalStorageProp('state') stateText: string = '未连接';

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
        .backgroundColor('#2E64E6')
        .borderRadius(12)
        .onClick(() => {
          postCardAction(this, {
            'action': 'message',
            'params': { 'command': 'toggle' }
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
