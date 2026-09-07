/**
 * 节点选择卡片
 * 移植自 upstream: packages/ssrvpn_shared/lib/widgets/ssrvpn_node_selection_node_card.dart
 * 延迟着色规则：<200 绿 / <500 警告黄 / 失败 红，与 upstream 一致。
 */
import { AppTheme, Palette } from '../theme/AppTheme';
import { ProxyNode } from '../commons/models/ProxyNode';
import { NodeCountryPolicy } from '../commons/services/PublicIpService';
import { CountryFlagIcon } from './CountryFlagIcon';

@Component
export struct NodeCard {
  @Prop node: ProxyNode | null = null;
  @Prop darkMode: boolean = true;
  @Prop selected: boolean = false;
  @Prop latencyMs: number = -2; // -2 未测试, -1 失败
  onSelect: (node: ProxyNode) => void = () => {};

  private pal(): Palette {
    return AppTheme.isDark(this.darkMode);
  }

  private latencyText(): string {
    if (this.latencyMs === -2) {
      return '—';
    }
    if (this.latencyMs === -1) {
      return '超时';
    }
    return `${this.latencyMs}ms`;
  }

  private latencyColor(): string {
    if (this.latencyMs === -2) {
      return this.pal().textHint;
    }
    if (this.latencyMs === -1) {
      return AppTheme.errorColor;
    }
    if (this.latencyMs < 200) {
      return AppTheme.successColor;
    }
    if (this.latencyMs < 500) {
      return AppTheme.warningColor;
    }
    return AppTheme.errorColor;
  }

  build() {
    if (this.node !== null) {
      Row({ space: 12 }) {
        CountryFlagIcon({ nodeName: this.node.name, iconSize: 20 })
        Column({ space: 2 }) {
          Text(NodeCountryPolicy.displayName(this.node.name))
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.selected ? AppTheme.primaryColor : this.pal().textPrimary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(`${this.node.server}:${this.node.port}`)
            .fontSize(12)
            .fontColor(this.pal().textHint)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)

        Text(this.latencyText())
          .fontSize(13)
          .fontColor(this.latencyColor())

        if (this.selected) {
          Text('✓')
            .fontSize(16)
            .fontColor(AppTheme.primaryColor)
        }
      }
      .width('100%')
      .padding(14)
      .borderRadius(AppTheme.cardRadius)
      .backgroundColor(this.selected ? this.pal().cardHover : this.pal().card)
      .borderWidth(this.selected ? 1.5 : 1)
      .borderColor(this.selected ? AppTheme.primaryColor : this.pal().border)
      .onClick(() => {
        if (this.node !== null) {
          this.onSelect(this.node);
        }
      })
    }
  }
}
