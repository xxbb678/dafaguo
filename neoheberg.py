#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import os
import sys

# ================= 强制干预环境：严禁 Python 把操控浏览器的内网通讯发给面板代理 =================
os.environ["NO_PROXY"] = "localhost,127.0.0.1,::1"
os.environ["no_proxy"] = "localhost,127.0.0.1,::1"

import json
import logging
import re
import time
import contextlib
import urllib.parse
import urllib.request
from datetime import datetime, timezone

# ================= 导入浏览器自动化库 =================
try:
    from ruyipage import FirefoxPage, FirefoxOptions
except ImportError:
    print("❌ 缺少依赖！请先在终端执行: pip install ruyipage")
    sys.exit(1)
# =============================================================

# ════════════════════════════════════════════════════════════════════
# 全局配置
# ════════════════════════════════════════════════════════════════════
BASE = "https://dash.neoheberg.fr"
ADS_URL = f"{BASE}/shop/ads"

JS_CLICK = (
    'var _b = document.getElementById("puzzleBtn");'
    'if (_b) {'
    '  var _r = _b.getBoundingClientRect();'
    '  var _x = _r.left + _r.width / 2;'
    '  var _y = _r.top + _r.height / 2;'
    '  ["mousedown","mouseup","click"].forEach(function(_t){'
    '    _b.dispatchEvent(new MouseEvent(_t, {bubbles:true, cancelable:true, clientX:_x, clientY:_y, button:0}));'
    '  });'
    '}'
)


BASE_WORK_DIR = os.environ.get("BROWSER_WORK_DIR", "/home/browser/browser-work")
WORK_DIR = os.path.join(BASE_WORK_DIR, "profiles")
os.makedirs(WORK_DIR, exist_ok=True)
try:
    os.chmod(WORK_DIR, 0o777)
except Exception:
    pass

STATE_FILE = os.path.join(WORK_DIR, "neoheberg_afk_state.json")
# 每日完成标记：文件名按「站点的计费周期」而非北京日期。
# 站点每日额度在每天 08:00（北京时间）重置，若直接用 date +%F：
#   - 08:00 前触发时站点仍显示昨天的 100/100，会误判「今天已完成」而写死标记
#   - 结果当天剩余时间全部不挂机，且状态一切正常、无人察觉
# 所以按站点周期算：当前小时早于重置点，说明站点还在跑昨天的周期，标记用昨天日期。
SITE_RESET_HOUR = int(os.environ.get("NH_SITE_RESET_HOUR", "8"))
_now = time.localtime()
if _now.tm_hour < SITE_RESET_HOUR:
    _site_day = time.strftime("%Y-%m-%d", time.localtime(time.time() - 86400))
else:
    _site_day = time.strftime("%Y-%m-%d")

# 用途：刷满 100 条后进程会正常退出，但 multi-account.sh 的每分钟看护 cron
# 会把"已干净退出"误判成"意外死亡"从而反复拉起，既空转又重复推送 TG 战报。
# 写这个标记后，启动与看护都会先检查它，避免重启。
DONE_MARKER = os.path.join(WORK_DIR, f"done-{_site_day}")

TG_BOT_TOKEN  = os.environ.get("TG_BOT_TOKEN", "")
TG_CHAT_ID    = os.environ.get("TG_CHAT_ID", "")
EMAIL         = os.environ.get("EMAIL", "")
PASSWORD      = os.environ.get("PASSWORD", "")
PROXY_URL     = os.environ.get("PROXY", "")
PROFILE_DIR   = os.environ.get("BROWSER_USER_DATA_DIR", "").strip()

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                    handlers=[logging.StreamHandler(sys.stdout)])
log = logging.getLogger("neoheberg-terminator")

def send_tg(text: str) -> None:
    if not TG_BOT_TOKEN or not TG_CHAT_ID:
        return
    try:
        data = json.dumps({"chat_id": TG_CHAT_ID, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(f"https://api.telegram.org/bot{TG_BOT_TOKEN}/sendMessage",
                                      data=data, headers={"Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=15)
    except Exception:
        pass

def load_state() -> dict:
    today_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    default_state = {"date": today_str, "start_balance": None, "rounds": 0}
    try:
        if os.path.exists(STATE_FILE):
            with open(STATE_FILE) as f:
                state = json.load(f)
                if state.get("date") != today_str:
                    log.info("📅 发现跨天旧缓存，直接作废，今日从零开始。")
                    return default_state
                return state
    except Exception:
        pass
    return default_state

def save_state(state: dict) -> None:
    try:
        with open(STATE_FILE, "w") as f:
            json.dump(state, f)
        os.chmod(STATE_FILE, 0o666)
    except Exception:
        pass

def get_balance_dom(page, wait: int = 0) -> float:
    """读取余额。等到页面真正渲染出余额数字后再返回。"""
    deadline = time.time() + max(0, wait)
    while True:
        try:
            # 先确认页面 DOM 已就绪（不是空白页）
            ready = page.run_js("return (document.body && document.body.innerText.length > 200) ? 1 : 0")
        except Exception:
            ready = 0

        if ready:
            try:
                clean = re.sub(r'<[^>]+>', ' ', page.html or "")
                clean = re.sub(r'\s+', ' ', clean)
                for pat in (r'Votre solde\s*([\d]+[,.][\d]+)',
                            r'Solde\s*([\d]+[,.][\d]+)',
                            r'([\d]+[,.][\d]+)\s*coins'):
                    m = re.search(pat, clean, re.IGNORECASE)
                    if m:
                        val = float(m.group(1).replace(",", "."))
                        if val > 0:
                            return val
            except Exception:
                pass

        if time.time() >= deadline:
            return 0.0
        time.sleep(1)


def get_seen_today(page) -> int:
    """读“今日已看 N / 100”。"""
    try:
        raw = page.html or ""
        # 去掉 HTML 注释（React 会插入 <!-- --> 分隔数字）
        raw = re.sub(r'<!--.*?-->', '', raw, flags=re.S)
        clean = re.sub(r'<[^>]+>', ' ', raw)
        clean = re.sub(r'\s+', ' ', clean)
        m = re.search(r'vues aujourd\s*.?\s*hui\s*(\d+)\s*/\s*100', clean, re.IGNORECASE)
        if not m:
            m = re.search(r'(\d+)\s*/\s*100', clean)
        return int(m.group(1)) if m else -1
    except Exception:
        return -1


def _is_cf_page(page):
    title = page.title or ""
    if "Just a moment" in title or "잠시만" in title: return True
    try: return bool(page.run_js(_CF_PRESENT_JS))
    except: return False

def wait_for_cloudflare(page, timeout=90, log_func=None):
    if not _is_cf_page(page):
        return True
        
    if log_func: log_func("🛡️ 拦截到大门 Cloudflare 验证盾，开始突破...")
    start = time.time()
    
    while time.time() - start < timeout:
        if not _is_cf_page(page):
            html = page.html or ""
            if "challenges.cloudflare.com" not in html and "cf-turnstile" not in html:
                return True
                
        try:
            with open(os.devnull, 'w') as f, contextlib.redirect_stderr(f):
                if hasattr(page, 'handle_cloudflare_challenge'):
                    page.handle_cloudflare_challenge(timeout=15)
        except Exception:
            pass
            
        time.sleep(3)
        if not _is_cf_page(page):
            if log_func: log_func("✅ 大门 CF 验证通过！")
            return True
            
    if log_func: log_func("❌ 外层 CF 验证超时")
    return False

# ════════════════════════════════════════════════════════════════════
# 自动登录模块 (集成专属 Cap 盾破拆)
# ════════════════════════════════════════════════════════════════════
def ensure_logged_in(page):
    identifier_input = page.ele('css:input#identifier')
    is_login_visible = identifier_input and identifier_input.is_displayed

    if not is_login_visible and "login" not in page.url:
        return True
        
    log.info("⚠️ 处于未登录状态，开始全自动登录...")
    if not EMAIL or not PASSWORD:
        log.error("❌ 未配置 EMAIL 或 PASSWORD，无法登录！")
        sys.exit(1)

    if not is_login_visible:
        conn_btn = page.ele('text:Connexion') or page.ele('text:Login')
        if conn_btn:
            conn_btn.click()
            time.sleep(3)
            identifier_input = page.ele('css:input#identifier')

    if identifier_input and identifier_input.is_displayed:
        log.info("✍️ 输入账号...")
        identifier_input.input(EMAIL, clear=True)
        time.sleep(1)
        
        next_btn = page.ele('css:button#goToPassword')
        if next_btn: next_btn.click()
        time.sleep(2) 
            
        pwd_input = page.ele('css:input#password')
        if pwd_input and pwd_input.is_displayed:
            log.info("🔑 输入密码...")
            pwd_input.input(PASSWORD, clear=True)
            time.sleep(1)

            cf_passed = False
            cap_widget = page.ele('css:cap-widget')
            if cap_widget:
                log.info("🛡️ 发现专属 Cap 验证码，准备穿透点击...")
                try:
                    page.run_js('document.querySelector("cap-widget").shadowRoot.querySelector(".captcha-trigger").click()')
                except:
                    cap_widget.click()
                    
                cap_token = page.ele('css:input[name="cap-token"]')
                if cap_token:
                    log.info("⏳ 死盯 Cap 验证码后台转圈获取 Token...")
                    for _ in range(20): 
                        if cap_token.attr("value"):
                            cf_passed = True
                            log.info("✅ 成功截获 Cap Token！")
                            break
                        time.sleep(1)
            else:
                page.handle_cloudflare_challenge(timeout=10)
                cf_input = page.ele('css:input[name="cf-turnstile-response"]')
                if cf_input:
                    for _ in range(10):
                        if cf_input.attr("value"):
                            cf_passed = True
                            break
                        time.sleep(1)
                else:
                    cf_passed = True

            if not cf_passed:
                log.error("❌ 验证码破解失败")
                return False

            log.info("🚀 发射登录表单！")
            submit_btn = page.ele('css:button[type="submit"]')
            if submit_btn: submit_btn.click()
            else: pwd_input.input('\n')
            
            time.sleep(5)
            wait_for_cloudflare(page, timeout=40)
            return True
            
    return False

# ════════════════════════════════════════════════════════════════════
# 主战场：浏览器纯物理挂机循环
# ════════════════════════════════════════════════════════════════════
def accept_privacy_gate(page):
    """NeoHeberg 隐私政策/CGU 同意墙（2026-10-05 起新增）。
    已登录账号会被拦在 /account/cgu?next=/shop/ads，必须点「J'accepte the Privacy Policy」
    才能进广告场。旧 cookie-同意处理只认 Consent/accepte 等短词，匹配不到这句长文案。
    应放在读余额之前调用，否则 start_balance 会被记成 0。"""
    try:
        clicked = page.run_js("""
            (() => {
                const btns = Array.from(
                    document.querySelectorAll('button, a[role=button], input[type=button]')
                );
                const b = btns.find(x => /accept/i.test((x.innerText||'') + ' ' + (x.value||'') + ' ' + (x.textContent||'')));
                if (b) { b.click(); return 'clicked'; }
                return 'no_button';
            })()
        """)
        log.info(f"同意墙按钮点击结果: {clicked}")
        return clicked == 'clicked'
    except Exception as e:
        log.warning(f"同意墙点击异常: {e}")
        return False


def main():
    state = load_state()

    if PROFILE_DIR and os.path.exists(PROFILE_DIR):
        for lock_name in ['lock', '.parentlock', 'parent.lock']:
            lf = os.path.join(PROFILE_DIR, lock_name)
            if os.path.exists(lf):
                try: os.remove(lf)
                except: pass

    page = None
    try:
        # 今日已完成则直接退出：不启动 Firefox、不登录、不重复推送 TG 战报。
        if os.path.exists(DONE_MARKER):
            log.info("ℹ️ 今日 100 条广告已刷满（完成标记存在），跳过本次启动。")
            try: os.remove(STATE_FILE)
            except: pass
            sys.exit(0)
        log.info("🤖 启动 Firefox 终结者版机器人...")
        opts = FirefoxOptions()
        # 自动定位 ruyipage 下载的 Firefox 运行时（版本号会变，不硬编码）
        import glob as _glob
        _ff = sorted(_glob.glob("/root/.cache/ruyipage/browsers/firefox-*/firefox/firefox"))
        if not _ff:
            log.error("❌ 未找到 Firefox 运行时，请先执行: python -m ruyipage install")
            sys.exit(1)
        opts.set_browser_path(_ff[-1])
        if PROFILE_DIR: opts.set_profile(PROFILE_DIR)
        if PROXY_URL: opts.set_proxy(PROXY_URL)
        opts.headless(False)
        page = FirefoxPage(opts)

        page.get(ADS_URL)
        time.sleep(5)
        wait_for_cloudflare(page, timeout=60, log_func=log.info)

        if not ensure_logged_in(page):
            log.error("❌ 登录失败，脚本退出。")
            sys.exit(1)

        # 隐私政策/CGU 同意墙必须在读余额之前处理，否则首页被墙盖住读到余额 0，
        # start_balance 会被错误记成 0。
        for _attempt in range(3):
            _u = page.url or ""
            if "/account/cgu" in _u or "/cgu" in _u or page.ele('text:Politique de confidentialité'):
                log.info("📋 检测到隐私政策/CGU 同意墙，先点接受再读余额...")
                accept_privacy_gate(page)
                time.sleep(3)
                page.get(ADS_URL)
                time.sleep(3)
            else:
                break

        bal = get_balance_dom(page, wait=20)
        if state.get("start_balance") is None:
            state["start_balance"] = bal
        state["last_balance"] = bal
        seen0 = get_seen_today(page)

        log.info("=========================================")
        log.info(f"✅ 纯物理火狐挂机任务开始！余额 {bal:.6f} coins，今日已看 {seen0}/100")
        log.info("=========================================")
        send_tg(f"🚀 <b>NeoHeberg 挂机启动</b>\n💰 原始分数: {bal:.2f} 分\n正在通过浏览器前台物理过盾连刷...")

        stuck_counter = 0
        # 连续异常计数：WebSocket / 浏览器会话这类故障，进程会一直活着空转报错，
        # 而看护 cron 只看 PID 是否存活，永远不会拉起它。
        # 达到阈值就主动退出，交给看护 cron 重新拉起一个干净实例。
        consec_errors = 0
        MAX_CONSEC_ERRORS = int(os.environ.get("NH_MAX_CONSEC_ERRORS", "20"))
        while True:
            try:
                curr_url = page.url or ""
                
                # ----------------- 主站逻辑 -----------------
                if "neoheberg.fr" in curr_url:
                    stuck_counter = 0
                    wait_for_cloudflare(page, timeout=15)
                    
                    # 同意墙：NeoHeberg 2026-10-05 更新隐私政策后，已登录账号会被拦在
                    # /account/cgu?next=/shop/ads，必须点「J'accepte la Privacy Policy」才能进广告场。
                    # 复用 accept_privacy_gate()（启动读余额前也调用了同一逻辑）。
                    if "/account/cgu" in curr_url or "/cgu" in curr_url or page.ele('text:Politique de confidentialité'):
                        log.info("📋 检测到隐私政策/CGU 同意墙，点接受继续...")
                        accept_privacy_gate(page)
                        time.sleep(3)
                        page.get(ADS_URL)
                        time.sleep(3)
                        continue
                        
                    if "/login" in curr_url:
                        ensure_logged_in(page)
                        continue
                        
                    if "/shop/ads" not in curr_url:
                        page.get(ADS_URL)
                        time.sleep(4)
                        continue
                        
                    # 检查是否刷满上限
                    if page.ele('text:100 / 100'):
                        bal = get_balance_dom(page, wait=20)
                        earned = bal - state["start_balance"]
                        msg = (f"🎉 <b>今日 100 条广告已刷满！</b>\n\n"
                               f"💰 原始分数: {state['start_balance']:.2f}\n"
                               f"💳 当前分数: {bal:.2f}\n"
                               f"📈 本次增加了: {earned:.2f} 分\n\n"
                               f"✅ 任务圆满结束，等待明日再战！")
                        log.info(msg.replace("<b>","").replace("</b>",""))
                        send_tg(msg)
                        try: os.remove(STATE_FILE)
                        except: pass
                        # 写完成标记：告知看护 cron「这是正常收工，别再拉起」
                        try:
                            with open(DONE_MARKER, "w") as f:
                                f.write(f"{time.strftime('%Y-%m-%d %H:%M:%S')} 余额 {bal:.6f} 今日 +{earned:.6f}\n")
                            os.chmod(DONE_MARKER, 0o600)
                        except Exception as e:
                            log.warning(f"写完成标记失败（看护可能重复拉起）: {e}")
                        sys.exit(0)
                        
                    # 寻找播放按钮
                    ad_btn = page.ele('css:button.ads-action-btn')
                    if ad_btn:
                        log.info("🖱️ 主站发车：点击观看广告按钮！")
                        try: ad_btn.click()
                        except: page.run_js('document.querySelector("button.ads-action-btn").click()')
                        time.sleep(5)
                    else:
                        log.info("⏳ 主站冷却：未发现广告按钮，等待 15 秒后刷新页面...")
                        time.sleep(15)
                        page.refresh()
                        
                # ----------------- 广告页巡逻逻辑 -----------------
                elif "clipurl.fr" in curr_url or "ad" in curr_url:
                    log.info(f"🎬 已进入广告场 ({curr_url.split('/')[2]})，启动高频安保巡逻...")
                    wait_loops = 0
                    
                    while "neoheberg.fr" not in (page.url or ""):
                        # 以防万一大门 CF 出现
                        wait_for_cloudflare(page, timeout=5)
                        
                        cap_widget = page.ele('css:cap-widget')
                        if cap_widget:
                            log.info("🛡️ 捕捉到广告页 Cap 盾！执行 Shadow DOM 破拆...")
                            try:
                                page.run_js('document.querySelector("cap-widget").shadowRoot.querySelector(".captcha-trigger").click()')
                            except:
                                cap_widget.click()
                                
                            # 盯住它直到出结果或消失
                            broke = False
                            for _ in range(15):
                                if not page.ele('css:cap-widget'):
                                    log.info("✅ 破盾成功，界面已放行！")
                                    broke = True
                                    break
                                cap_token = page.ele('css:input[name="cap-token"]')
                                if cap_token and cap_token.attr("value"):
                                    log.info("✅ 破盾成功，已产出安全 Token！")
                                    broke = True
                                    break
                                time.sleep(1)
                            # 关键：产出 token 后页面需要时间跳转，
                            # 不能立即重试，否则 widget 尚未移除会无限循环
                            if broke:
                                time.sleep(3)
                                if "neoheberg.fr" in (page.url or ""):
                                    break
                            wait_loops = 0
                            
                        # ================= 新增：打地鼠小游戏外挂 =================
                        elif page.run_js("return !!document.getElementById('puzzleBtn')"):
                            log.info("🎮 触发【打地鼠】防刷游戏，启动自瞄外挂！")
                            # 靶子 = #puzzleBtn，在 #puzzleArea 内随机移动，点 5 次通关
                            for _ in range(80):
                                gone = page.run_js("return !document.getElementById('puzzleBtn')")
                                if gone:
                                    log.info("✅ 打地鼠完成，靶子已消失")
                                    break
                                txt = page.run_js("return (document.getElementById('puzzleBtn')||{}).innerText||''")
                                try:
                                    page.run_js(JS_CLICK)
                                    log.info("🔫 开火 [" + str(txt) + "]")
                                except Exception:
                                    pass
                                time.sleep(0.35)
                            wait_loops = 0
                        # =======================================================
                        
                        else:
                            # 兜底检测常规 CF
                            cf_input = page.ele('css:input[name="cf-turnstile-response"]')
                            if cf_input and not cf_input.attr("value"):
                                try: page.handle_cloudflare_challenge(timeout=10)
                                except: pass
                                
                            wait_loops += 1
                            if wait_loops % 5 == 0:
                                log.info(f"⏳ 正在监视倒计时读条或等待下一道防线... (已等 {wait_loops * 2} 秒)")
                                
                            if wait_loops > 100:
                                log.warning("⚠️ 广告页卡住超 3 分钟无进展，强制撤退回主站...")
                                page.get(ADS_URL)
                                break
                                
                        time.sleep(2)
                        
                    # 跳出广告页循环，说明回到了主站
                    if "neoheberg.fr" in (page.url or ""):
                        state["rounds"] += 1
                        # 关键：等余额 DOM 元素真正出现（页面刚跳回来时 url 已变但 DOM 未就绪）
                        for _w in range(25):
                            try:
                                ok = page.run_js("return !!document.querySelector('p.text-lg.font-bold') || document.body.innerText.indexOf('Votre solde') >= 0")
                            except Exception:
                                ok = False
                            if ok:
                                break
                            time.sleep(1)
                        time.sleep(1)
                        bal = get_balance_dom(page, wait=10)
                        seen = get_seen_today(page)
                        gained = bal - (state.get("last_balance") or bal)
                        state["last_balance"] = bal
                        log.info(f"🎉 历劫归来！第 {state['rounds']} 轮完成！余额 {bal:.6f} coins（本轮 +{gained:.6f}）已看 {seen}/100")
                        save_state(state)
                        
                # ----------------- 迷路处理 -----------------
                else:
                    stuck_counter += 1
                    if stuck_counter > 5:
                        log.warning(f"⚠️ 机器人迷路 (当前URL: {curr_url})，强行拉回主站...")
                        page.get(ADS_URL)
                        stuck_counter = 0
                    time.sleep(3)
                    
                consec_errors = 0   # 跑到这里说明本轮循环正常跑完，计数清零
            except Exception as e:
                consec_errors += 1
                if consec_errors >= MAX_CONSEC_ERRORS:
                    log.error(f"❌ 连续 {consec_errors} 次异常，判定卡死，退出交给看护 cron 重启")
                    log.error(f"   最后异常: {e}")
                    log.error("   若是 WebSocket 断连，通常是长连接被对端掐断，重启即可恢复")
                    try: os.remove(STATE_FILE)
                    except: pass
                    sys.exit(1)
                time.sleep(5)
                
    except Exception as e:
        log.error(f"❌ 严重错误导致退出: {e}")
        import traceback
        traceback.print_exc()
    finally:
        if page: page.quit()

if __name__ == "__main__":
    main()