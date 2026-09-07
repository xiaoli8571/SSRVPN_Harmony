/**
 * 毛玻璃容器
 * 移植自 upstream: SSRVPN_Android/lib/widgets/glass_container.dart
 *                packages/ssrvpn_shared/lib/widgets/glass_container_part.dart
 * Flutter 的 BackdropFilter + liquid_lens.frag 着色器用 ArkUI backgroundEffect 等价实现。
 */
import { AppTheme } from '../theme/AppTheme';

@Component
export struct GlassContainer {
  @Prop darkMode: boolean = true;
  @Prop radius: number = 16;
  @Prop paddingV: number = 16;
  @Prop paddingH: number = 16;
  @Builder
  emptyContent() {
  }
  @BuilderParam content: () => void = this.emptyContent;

  build() {
    Column() {
      Column() {
        this.content()
      }
      .width('100%')
    }
    .padding({ top: this.paddingV, bottom: this.paddingV, left: this.paddingH, right: this.paddingH })
    .borderRadius(this.radius)
    .backgroundColor(this.darkMode ? AppTheme.darkCard : AppTheme.lightCard)
    .backgroundBlurStyle(BlurStyle.COMPONENT_THICK, {
      colorMode: ThemeColorMode.DARK,
      adaptiveColor: AdaptiveColor.DEFAULT
    })
    .backgroundEffect({ radius: 24, saturation: 1.2, brightness: 1.0 })
    .borderWidth(1)
    .borderColor(this.darkMode ? AppTheme.darkBorder : AppTheme.lightBorder)
  }
}

/** 液态透镜高光层：liquid_lens.frag 的近似视觉（顶部高光渐变） */
@Component
export struct LiquidLensOverlay {
  @Prop darkMode: boolean = true;

  build() {
    Column()
      .linearGradient({
        angle: 160,
        colors: this.darkMode
          ? [['#FFFFFF14', 0.0], ['#FFFFFF00', 0.35]]
          : [['#FFFFFF66', 0.0], ['#FFFFFF00', 0.4]]
      })
  }
}
