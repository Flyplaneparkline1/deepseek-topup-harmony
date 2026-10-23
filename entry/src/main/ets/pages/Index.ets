import { webview } from '@kit.ArkWeb';
import { http } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { common, Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';

/** 充值页（直达，不经过官网首页） */
const TOP_UP_URL: string = 'https://platform.deepseek.com/top_up';
/** 官方余额接口，用于在标题栏显示余额 */
const BALANCE_URL: string = 'https://api.deepseek.com/user/balance';
const PREF_NAME: string = 'ds_shell';
const PREF_KEY: string = 'apiKey';
/** 余额自动刷新节流（毫秒） */
const REFRESH_THROTTLE: number = 3000;

interface BalanceInfo {
  currency: string;
  total_balance: string;
  granted_balance: string;
  topped_up_balance: string;
}

interface BalanceResp {
  is_available: boolean;
  balance_infos: BalanceInfo[];
}

@Entry
@Component
struct Index {
  private controller: webview.WebviewController = new webview.WebviewController();
  @State balanceText: string = '--';
  @State loading: boolean = true;
  @State keyDialogVisible: boolean = false;
  @State keyInput: string = '';

  private prefs: preferences.Preferences | undefined = undefined;
  private lastFetch: number = 0;
  /** 跳出去支付过，回到前台时需要刷新页面以同步订单状态 */
  private pendingPayment: boolean = false;

  aboutToAppear(): void {
    this.initStore();
  }

  /**
   * 从支付宝/微信回到 App 时触发：
   * 1) 如果刚才去付过款，刷新页面让充值页同步最新订单；
   * 2) 顺手刷一次余额（节流）。
   */
  onPageShow(): void {
    if (this.pendingPayment) {
      this.pendingPayment = false;
      try {
        this.controller.refresh();
      } catch (e) {
        // controller 还没挂上，忽略
      }
    }
    this.refreshBalanceThrottled();
  }

  /** 系统返回键：优先在网页内部后退，退无可退才退出 App */
  onBackPress(): boolean {
    try {
      if (this.controller.accessBackward()) {
        this.controller.backward();
        return true;
      }
    } catch (e) {
      // 忽略
    }
    return false;
  }

  private async initStore(): Promise<void> {
    const ctx = this.getUIContext().getHostContext();
    if (ctx === undefined) {
      return;
    }
    try {
      this.prefs = await preferences.getPreferences(ctx, { name: PREF_NAME });
      const saved = await this.prefs.get(PREF_KEY, '');
      if (typeof saved === 'string') {
        this.keyInput = saved;
      }
    } catch (e) {
      // 存储不可用不影响主流程，网页照常能开、能充值
      console.error('init preferences failed: ' + JSON.stringify(e));
    }
    await this.refreshBalance();
  }

  private refreshBalanceThrottled(): void {
    const now: number = Date.now();
    if (now - this.lastFetch < REFRESH_THROTTLE) {
      return;
    }
    this.refreshBalance();
  }

  /**
   * 用 API Key 调官方余额接口。
   * 注意：这里的余额就是开放平台账户余额（与充值页显示的是同一个数）。
   * Key 只存本机 preferences，不上传任何第三方。
   */
  private async refreshBalance(): Promise<void> {
    const key: string = this.keyInput.trim();
    if (key.length === 0) {
      this.balanceText = '未设置 Key';
      return;
    }
    this.lastFetch = Date.now();
    const req = http.createHttp();
    try {
      const headers: Record<string, string> = {
        'Authorization': 'Bearer ' + key,
        'Accept': 'application/json'
      };
      const resp = await req.request(BALANCE_URL, {
        method: http.RequestMethod.GET,
        header: headers,
        connectTimeout: 8000,
        readTimeout: 8000,
        expectDataType: http.HttpDataType.STRING
      });
      if (resp.responseCode !== 200) {
        this.balanceText = '查询失败 ' + resp.responseCode;
        return;
      }
      const body: BalanceResp = JSON.parse(resp.result as string) as BalanceResp;
      const infos: BalanceInfo[] = body.balance_infos;
      if (infos === undefined || infos.length === 0) {
        this.balanceText = '0.00';
        return;
      }
      let picked: BalanceInfo = infos[0];
      for (let i = 0; i < infos.length; i++) {
        if (infos[i].currency === 'CNY') {
          picked = infos[i];
        }
      }
      this.balanceText = picked.total_balance;
    } catch (e) {
      const err = e as BusinessError;
      this.balanceText = '查询失败';
      console.error('balance request failed: ' + JSON.stringify(err));
    } finally {
      req.destroy();
    }
  }

  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message });
    } catch (e) {
      // 提示失败不影响主流程
    }
  }

  private async saveKey(): Promise<void> {
    const k: string = this.keyInput.trim();
    if (k.length > 0 && !k.startsWith('sk-')) {
      this.toast('DeepSeek 的 Key 一般以 sk- 开头，请确认');
    }
    if (this.prefs !== undefined) {
      try {
        await this.prefs.put(PREF_KEY, k);
        await this.prefs.flush();
      } catch (e) {
        this.toast('Key 保存失败');
      }
    }
    this.keyInput = k;
    this.keyDialogVisible = false;
    this.lastFetch = 0;
    await this.refreshBalance();
  }

  /** 需要交给系统其它应用处理的协议头（支付类最关键） */
  private isExternalScheme(url: string): boolean {
    const u: string = url.toLowerCase();
    return u.startsWith('alipays://')
      || u.startsWith('alipayqr://')
      || u.startsWith('alipay://')
      || u.startsWith('weixin://')
      || u.startsWith('tel:')
      || u.startsWith('mailto:');
  }

  /**
   * WebView 本身不认识 alipays:// 这类协议，直接加载会白屏。
   * 必须拦截后转成 Want 交给系统拉起支付宝/微信。
   * 前提：module.json5 里声明了 querySchemes。
   */
  private openExternal(url: string): void {
    const ctx = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const want: Want = {
      action: 'ohos.want.action.viewData',
      uri: url
    };
    ctx.startAbility(want).then(() => {
      this.pendingPayment = url.toLowerCase().startsWith('alipays') || url.toLowerCase().startsWith('weixin');
    }).catch((err: BusinessError) => {
      this.toast('无法打开外部应用（错误码 ' + err.code + '）');
    });
  }

  @Builder
  Header() {
    Row() {
      Text('DeepSeek')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor('#111111')
      Blank()
      Row({ space: 4 }) {
        Text('余额')
          .fontSize(11)
          .fontColor('#666666')
        Text(this.balanceText)
          .fontSize(13)
          .fontWeight(FontWeight.Medium)
          .fontColor('#0A7CFF')
      }
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .backgroundColor('#F1F5FF')
      .borderRadius(14)
      .margin({ right: 8 })
      .onClick(() => {
        this.lastFetch = 0;
        this.refreshBalance();
      })

      Text('Key')
        .fontSize(12)
        .fontColor('#0A7CFF')
        .padding({ left: 10, right: 10, top: 6, bottom: 6 })
        .borderRadius(14)
        .backgroundColor('#F1F5FF')
        .onClick(() => {
          this.keyDialogVisible = true;
        })
    }
    .width('100%')
    .height(52)
    .padding({ left: 16, right: 12 })
    .backgroundColor('#FFFFFF')
    .border({ width: { bottom: 0.5 }, color: '#E5E5E5' })
  }

  @Builder
  KeyPanel() {
    Column() {
      Column({ space: 12 }) {
        Text('API Key')
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor('#111111')
        Text('仅保存在本机，用于查询余额（GET /user/balance）。充值/支付仍走官方网页，不经过本应用。')
          .fontSize(12)
          .fontColor('#888888')
          .lineHeight(18)
        TextInput({ text: this.keyInput, placeholder: 'sk-...' })
          .type(InputType.Password)
          .height(44)
          .onChange((value: string) => {
            this.keyInput = value;
          })
        Row({ space: 12 }) {
          Button('取消')
            .layoutWeight(1)
            .height(40)
            .backgroundColor('#F2F2F2')
            .fontColor('#333333')
            .onClick(() => {
              this.keyDialogVisible = false;
            })
          Button('保存')
            .layoutWeight(1)
            .height(40)
            .onClick(() => {
              this.saveKey();
            })
        }
        .width('100%')
      }
      .width('86%')
      .padding(20)
      .backgroundColor('#FFFFFF')
      .borderRadius(16)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('rgba(0, 0, 0, 0.45)')
  }

  build() {
    Stack() {
      Column() {
        this.Header()
        Stack() {
          Web({ src: TOP_UP_URL, controller: this.controller })
            .domStorageAccess(true)
            .javaScriptAccess(true)
            .fileAccess(false)
            .mixedMode(MixedMode.All)
            .zoomAccess(true)
            .horizontalScrollBarAccess(false)
            .verticalScrollBarAccess(false)
            .darkMode(WebDarkMode.Auto)
            .onPageBegin(() => {
              this.loading = true;
            })
            .onPageEnd(() => {
              this.loading = false;
              this.refreshBalanceThrottled();
            })
            .onLoadIntercept((event) => {
              const url: string = event.data.getRequestUrl();
              if (this.isExternalScheme(url)) {
                this.openExternal(url);
                return true;
              }
              return false;
            })
            .width('100%')
            .height('100%')

          if (this.loading) {
            Column() {
              LoadingProgress()
                .width(48)
                .height(48)
                .color('#0A7CFF')
              Text('加载中…')
                .fontSize(12)
                .fontColor('#999999')
                .margin({ top: 8 })
            }
            .width('100%')
            .height('100%')
            .justifyContent(FlexAlign.Center)
            .backgroundColor('#FFFFFF')
          }
        }
        .layoutWeight(1)
      }
      .width('100%')
      .height('100%')

      if (this.keyDialogVisible) {
        this.KeyPanel()
      }
    }
    .width('100%')
    .height('100%')
  }
}
