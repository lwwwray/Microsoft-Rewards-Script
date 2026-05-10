#!/usr/bin/env bash
set -euo pipefail

# 确保 Playwright 使用预安装的浏览器
export PLAYWRIGHT_BROWSERS_PATH=0

SCRIPT_DIR="/usr/src/microsoft-rewards-script"
DIST_DIR="$SCRIPT_DIR/dist"

# ─────────────────────────────────────────────────────────────────────────────
# 1. 时区设置：未提供时默认使用 UTC
# ─────────────────────────────────────────────────────────────────────────────
: "${TZ:=UTC}"
ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime
echo "$TZ" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata

# 2. 验证 CRON_SCHEDULE
if [ -z "${CRON_SCHEDULE:-}" ]; then
  echo "错误: 未设置 CRON_SCHEDULE 环境变量。" >&2
  echo "请设置 CRON_SCHEDULE (例如，\"0 2 * * *\")." >&2
  exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. 账户配置：从 ACCOUNT_N_* 环境变量生成 accounts.json
#
#    在 .env 中为每个账户添加编号块，从 1 开始：
#      ACCOUNT_1_EMAIL, ACCOUNT_1_PASSWORD, ...
#      ACCOUNT_2_EMAIL, ACCOUNT_2_PASSWORD, ...
#
#    所有字段与 accounts.example.json 完全对应。
#    当第一个 ACCOUNT_N_EMAIL 缺失时循环停止。
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_DIR="$DIST_DIR/config"
mkdir -p "$CONFIG_DIR"

ACCOUNTS_FILE="$CONFIG_DIR/accounts.json"

_build_account_json() {
  local email="$1"
  local password="$2"
  local totp="${3:-}"
  local recovery="${4:-}"
  local geo="${5:-auto}"
  local lang="${6:-en}"
  local proxy_axios="${7:-false}"
  local proxy_url="${8:-}"
  local proxy_port="${9:-0}"
  local proxy_user="${10:-}"
  local proxy_pass="${11:-}"

  jq -n \
    --arg email "$email" \
    --arg password "$password" \
    --arg totp "$totp" \
    --arg recovery "$recovery" \
    --arg geo "$geo" \
    --arg lang "$lang" \
    --argjson proxyAxios "$proxy_axios" \
    --arg proxyUrl "$proxy_url" \
    --argjson proxyPort "$proxy_port" \
    --arg proxyUser "$proxy_user" \
    --arg proxyPass "$proxy_pass" \
    '{
      email: $email,
      password: $password,
      totpSecret: $totp,
      recoveryEmail: $recovery,
      geoLocale: $geo,
      langCode: $lang,
      proxy: {
        proxyAxios: $proxyAxios,
        url: $proxyUrl,
        port: $proxyPort,
        username: $proxyUser,
        password: $proxyPass
      },
      saveFingerprint: {
        mobile: false,
        desktop: false
      }
    }'
}

account_array="[]"
i=1
while true; do
  email_var="ACCOUNT_${i}_EMAIL"
  pass_var="ACCOUNT_${i}_PASSWORD"
  email="${!email_var:-}"
  [ -z "$email" ] && break
  pass="${!pass_var:?ERROR: ${pass_var} must be set when ${email_var} is set}"

  totp_var="ACCOUNT_${i}_TOTP_SECRET";      totp="${!totp_var:-}"
  rec_var="ACCOUNT_${i}_RECOVERY_EMAIL";    rec="${!rec_var:-}"
  geo_var="ACCOUNT_${i}_GEO_LOCALE";        geo="${!geo_var:-auto}"
  lang_var="ACCOUNT_${i}_LANG_CODE";        lang="${!lang_var:-en}"
  paxios_var="ACCOUNT_${i}_PROXY_AXIOS";    paxios="${!paxios_var:-false}"
  purl_var="ACCOUNT_${i}_PROXY_URL";        purl="${!purl_var:-}"
  pport_var="ACCOUNT_${i}_PROXY_PORT";      pport="${!pport_var:-0}"
  puser_var="ACCOUNT_${i}_PROXY_USERNAME";  puser="${!puser_var:-}"
  ppass_var="ACCOUNT_${i}_PROXY_PASSWORD";  ppass="${!ppass_var:-}"

  account_json=$(_build_account_json "$email" "$pass" "$totp" "$rec" "$geo" "$lang" "$paxios" "$purl" "$pport" "$puser" "$ppass")
  account_array=$(echo "$account_array" | jq ". + [$account_json]")
  i=$((i + 1))
done

if [ "$(echo "$account_array" | jq 'length')" -gt 0 ]; then
  echo "$account_array" > "$ACCOUNTS_FILE"
  echo "[entrypoint] accounts.json 已写入，共 $(echo "$account_array" | jq 'length') 个账户"
else
  echo "警告: 未找到 ACCOUNT_1_EMAIL，accounts.json 未写入 — 脚本可能无法运行。" >&2
  echo "      请在 .env 文件中设置 ACCOUNT_1_EMAIL 和 ACCOUNT_1_PASSWORD。" >&2
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. 配置文件：生成并更新 config.json
#
#    行为说明：
#      - 不存在 config.json       → 以 config.example.json 为模板复制生成
#      - config.json 已存在       → 直接使用（无论是用户编辑的还是之前生成的）
#                                   CONFIG_* 覆盖始终会应用
#      - 配置字段漂移（新增字段） → 警告并列出缺失的字段，不自动修改文件
#
#    headless 始终强制为 true — 在 Docker 中不支持有界面模式。
#
#    CONFIG_* 环境变量覆盖（每次启动时应用）：
#
#    通用配置：
#      CONFIG_CLUSTERS=2                 → .clusters（并发账户数）
#      CONFIG_DEBUG_LOGS=true            → .debugLogs（调试日志）
#      CONFIG_ERROR_DIAGNOSTICS=true     → .errorDiagnostics（错误诊断）
#      CONFIG_GLOBAL_TIMEOUT=30sec       → .globalTimeout（全局超时）
#
#    任务开关（布尔值）：
#      CONFIG_WORKER_DAILY_SET           → .workers.doDailySet（每日任务）
#      CONFIG_WORKER_SPECIAL_PROMOTIONS  → .workers.doSpecialPromotions（特殊活动）
#      CONFIG_WORKER_MORE_PROMOTIONS     → .workers.doMorePromotions（更多推广）
#      CONFIG_WORKER_PUNCH_CARDS         → .workers.doPunchCards（打卡任务）
#      CONFIG_WORKER_APP_PROMOTIONS      → .workers.doAppPromotions（应用推广）
#      CONFIG_WORKER_DESKTOP_SEARCH      → .workers.doDesktopSearch（桌面搜索）
#      CONFIG_WORKER_MOBILE_SEARCH       → .workers.doMobileSearch（手机搜索）
#      CONFIG_WORKER_DAILY_CHECKIN       → .workers.doDailyCheckIn（每日签到）
#      CONFIG_WORKER_READ_TO_EARN        → .workers.doReadToEarn（阅读赚分）
#
#    搜索设置：
#      CONFIG_SEARCH_SCROLL_RANDOM       → .searchSettings.scrollRandomResults
#      CONFIG_SEARCH_CLICK_RANDOM        → .searchSettings.clickRandomResults
#      CONFIG_SEARCH_PARALLEL            → .searchSettings.parallelSearching
#      CONFIG_SEARCH_DELAY_MIN           → .searchSettings.searchDelay.min
#      CONFIG_SEARCH_DELAY_MAX           → .searchSettings.searchDelay.max
#      CONFIG_SEARCH_READ_DELAY_MIN      → .searchSettings.readDelay.min
#      CONFIG_SEARCH_READ_DELAY_MAX      → .searchSettings.readDelay.max
#      CONFIG_SEARCH_VISIT_TIME          → .searchSettings.searchResultVisitTime
#      CONFIG_SEARCH_ON_BING_LOCAL       → .searchOnBingLocalQueries
#
#    代理：
#      CONFIG_PROXY_QUERY_ENGINE         → .proxy.queryEngine
#
#    控制台日志过滤：
#      CONFIG_LOG_FILTER_ENABLED         → .consoleLogFilter.enabled
#      CONFIG_LOG_FILTER_MODE            → .consoleLogFilter.mode (whitelist|blacklist)
#      CONFIG_LOG_FILTER_LEVELS          → .consoleLogFilter.levels（逗号分隔）
#      CONFIG_LOG_FILTER_KEYWORDS        → .consoleLogFilter.keywords（逗号分隔）
#
#    Webhook 推送：
#      CONFIG_DISCORD_ENABLED / CONFIG_DISCORD_URL
#      CONFIG_NTFY_ENABLED / CONFIG_NTFY_URL / CONFIG_NTFY_TOPIC / CONFIG_NTFY_TOKEN
#      CONFIG_NTFY_TITLE / CONFIG_NTFY_PRIORITY
#      CONFIG_NTFY_TAGS                  → 逗号分隔，如 "bot,notify"
#
#    Webhook 日志过滤：
#      CONFIG_WEBHOOK_LOG_FILTER_ENABLED  → .webhook.webhookLogFilter.enabled
#      CONFIG_WEBHOOK_LOG_FILTER_MODE     → .webhook.webhookLogFilter.mode
#      CONFIG_WEBHOOK_LOG_FILTER_LEVELS   → 逗号分隔
#      CONFIG_WEBHOOK_LOG_FILTER_KEYWORDS → 逗号分隔
#
# ─────────────────────────────────────────────────────────────────────────────
CONFIG_FILE="$CONFIG_DIR/config.json"
CONFIG_EXAMPLE="$SCRIPT_DIR/src/config.example.json"

# 检查 config.json 是否存在且为合法的 JSON 对象，是则返回 0
_config_file_is_valid() {
  [ -f "$CONFIG_FILE" ] && \
  [ "$(wc -c < "$CONFIG_FILE")" -gt 10 ] && \
  jq -e 'type == "object"' "$CONFIG_FILE" > /dev/null 2>&1
}

# 返回示例文件中有但当前 config.json 中缺失的键路径
_find_new_keys() {
  local config_keys example_keys
  local jq_expr='[path(..)] | map(select(all(. ; type == "string")) | join(".")) | sort[]'
  config_keys=$(jq -r "$jq_expr" "$CONFIG_FILE" 2>/dev/null)
  example_keys=$(jq -r "$jq_expr" "$CONFIG_EXAMPLE" 2>/dev/null)
  comm -13 <(echo "$config_keys") <(echo "$example_keys")
}

if ! [ -f "$CONFIG_EXAMPLE" ]; then
  echo "错误: 在 $CONFIG_EXAMPLE 找不到 config.example.json — 镜像可能已损坏。" >&2
  exit 1
fi

if _config_file_is_valid; then
  echo "[entrypoint] 检测到已有 config.json，直接使用。"
  new_keys=$(_find_new_keys)
  if [ -n "$new_keys" ]; then
    echo "" >&2
    echo "┌─────────────────────────────────────────────────────────┐" >&2
    echo "│  ⚠  配置文件需要更新                                    │" >&2
    echo "│                                                         │" >&2
    echo "│  您的 config.json 缺少近期更新中新增的配置项。          │" >&2
    echo "│  脚本仍可运行，但新功能可能无法正常工作。               │" >&2
    echo "│                                                         │" >&2
    echo "│  缺失的配置项（默认值请参考 config.example.json）：     │" >&2
    echo "$new_keys" | while IFS= read -r key; do
      printf "│    %-55s│\n" "+ $key" >&2
    done
    echo "│                                                         │" >&2
    echo "│  修复方法：删除 ./config/config.json 并重启容器 —       │" >&2
    echo "│  系统将使用最新默认值重新生成，然后重新应用             │" >&2
    echo "│  CONFIG_* 环境变量即可。                                │" >&2
    echo "└─────────────────────────────────────────────────────────┘" >&2
    echo "" >&2
  fi
else
  echo "[entrypoint] 未找到 config.json — 正在从 config.example.json 生成。"
  cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
  echo "[entrypoint] config.json 已创建，可通过 compose.yaml 中的 CONFIG_* 环境变量自定义配置。"
fi

# 应用 CONFIG_* 环境变量覆盖（每次启动时执行，与配置来源无关）
echo "[entrypoint] 正在应用 CONFIG_* 环境变量覆盖..."
_cfg() {
  # _cfg <环境变量值或空> <jq路径> <类型: string|bool|number>
  local val="$1" path="$2" type="${3:-string}"
  [ -z "$val" ] && return 0
  case "$type" in
    bool|number)
      jq --argjson v "$val" "$path = \$v" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      ;;
    *)
      jq --arg v "$val" "$path = \$v" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
      ;;
  esac
  echo "[entrypoint]   $path = $val"
}

# headless 始终强制为 true — Docker 容器内不支持有界面模式
_cfg 'true'                            '.headless'                                  bool

# 顶层配置
_cfg "${CONFIG_CLUSTERS:-}"            '.clusters'                                  number
_cfg "${CONFIG_DEBUG_LOGS:-}"          '.debugLogs'                                 bool
_cfg "${CONFIG_ERROR_DIAGNOSTICS:-}"   '.errorDiagnostics'                          bool
_cfg "${CONFIG_GLOBAL_TIMEOUT:-}"      '.globalTimeout'                             string

# 任务开关
_cfg "${CONFIG_WORKER_DAILY_SET:-}"           '.workers.doDailySet'           bool
_cfg "${CONFIG_WORKER_SPECIAL_PROMOTIONS:-}"  '.workers.doSpecialPromotions'   bool
_cfg "${CONFIG_WORKER_MORE_PROMOTIONS:-}"     '.workers.doMorePromotions'      bool
_cfg "${CONFIG_WORKER_PUNCH_CARDS:-}"         '.workers.doPunchCards'          bool
_cfg "${CONFIG_WORKER_APP_PROMOTIONS:-}"      '.workers.doAppPromotions'       bool
_cfg "${CONFIG_WORKER_DESKTOP_SEARCH:-}"      '.workers.doDesktopSearch'       bool
_cfg "${CONFIG_WORKER_MOBILE_SEARCH:-}"       '.workers.doMobileSearch'        bool
_cfg "${CONFIG_WORKER_DAILY_CHECKIN:-}"       '.workers.doDailyCheckIn'        bool
_cfg "${CONFIG_WORKER_READ_TO_EARN:-}"        '.workers.doReadToEarn'          bool

# 搜索设置
_cfg "${CONFIG_SEARCH_SCROLL_RANDOM:-}"    '.searchSettings.scrollRandomResults'    bool
_cfg "${CONFIG_SEARCH_CLICK_RANDOM:-}"     '.searchSettings.clickRandomResults'     bool
_cfg "${CONFIG_SEARCH_PARALLEL:-}"         '.searchSettings.parallelSearching'      bool
_cfg "${CONFIG_SEARCH_DELAY_MIN:-}"        '.searchSettings.searchDelay.min'        string
_cfg "${CONFIG_SEARCH_DELAY_MAX:-}"        '.searchSettings.searchDelay.max'        string
_cfg "${CONFIG_SEARCH_READ_DELAY_MIN:-}"   '.searchSettings.readDelay.min'          string
_cfg "${CONFIG_SEARCH_READ_DELAY_MAX:-}"   '.searchSettings.readDelay.max'          string
_cfg "${CONFIG_SEARCH_VISIT_TIME:-}"       '.searchSettings.searchResultVisitTime'  string
_cfg "${CONFIG_SEARCH_ON_BING_LOCAL:-}"    '.searchOnBingLocalQueries'              bool

# 代理设置
_cfg "${CONFIG_PROXY_QUERY_ENGINE:-}"  '.proxy.queryEngine'  bool

# 控制台日志过滤
# levels 和 keywords 支持逗号分隔的多个值，如 "error,warn"
_cfg "${CONFIG_LOG_FILTER_ENABLED:-}"   '.consoleLogFilter.enabled'  bool
_cfg "${CONFIG_LOG_FILTER_MODE:-}"      '.consoleLogFilter.mode'     string
_cfg_array() {
  # _cfg_array <值或未设置标记> <jq路径>
  # 使用 __UNSET__ 哨兵值区分「变量未设置」和「变量设为空」。
  # 空值写入 []；未设置的变量则跳过。
  local val="$1" path="$2"
  [ "$val" = "__UNSET__" ] && return 0
  local json_array
  if [ -z "$val" ]; then
    json_array="[]"
  else
    json_array=$(echo "$val" | jq -Rc '[split(",") | .[] | ltrimstr(" ") | rtrimstr(" ")]')
  fi
  jq --argjson v "$json_array" "$path = \$v" "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
  echo "[entrypoint]   $path = [$val]"
}
_cfg_array "${CONFIG_LOG_FILTER_LEVELS-__UNSET__}"    '.consoleLogFilter.levels'
_cfg_array "${CONFIG_LOG_FILTER_KEYWORDS-__UNSET__}"  '.consoleLogFilter.keywords'

# Discord 推送
_cfg "${CONFIG_DISCORD_ENABLED:-}"  '.webhook.discord.enabled'  bool
_cfg "${CONFIG_DISCORD_URL:-}"      '.webhook.discord.url'      string

# ntfy 推送
_cfg "${CONFIG_NTFY_ENABLED:-}"   '.webhook.ntfy.enabled'   bool
_cfg "${CONFIG_NTFY_URL:-}"       '.webhook.ntfy.url'       string
_cfg "${CONFIG_NTFY_TOPIC:-}"     '.webhook.ntfy.topic'     string
_cfg "${CONFIG_NTFY_TOKEN:-}"     '.webhook.ntfy.token'     string
_cfg "${CONFIG_NTFY_TITLE:-}"     '.webhook.ntfy.title'     string
_cfg "${CONFIG_NTFY_PRIORITY:-}"  '.webhook.ntfy.priority'  number
_cfg_array "${CONFIG_NTFY_TAGS-__UNSET__}"  '.webhook.ntfy.tags'

# PushPlus 微信推送
_cfg "${CONFIG_PUSHPLUS_ENABLED:-}"   '.webhook.pushplus.enabled'   bool
_cfg "${CONFIG_PUSHPLUS_TOKEN:-}"     '.webhook.pushplus.token'     string
_cfg "${CONFIG_PUSHPLUS_TITLE:-}"     '.webhook.pushplus.title'     string
_cfg "${CONFIG_PUSHPLUS_TEMPLATE:-}"  '.webhook.pushplus.template'  string
_cfg "${CONFIG_PUSHPLUS_CHANNEL:-}"   '.webhook.pushplus.channel'   string

# Server酱推送
_cfg "${CONFIG_SERVERCHAN_ENABLED:-}"  '.webhook.serverchan.enabled'  bool
_cfg "${CONFIG_SERVERCHAN_SENDKEY:-}"  '.webhook.serverchan.sendkey'  string
_cfg "${CONFIG_SERVERCHAN_TITLE:-}"    '.webhook.serverchan.title'    string
_cfg "${CONFIG_SERVERCHAN_SHORT:-}"    '.webhook.serverchan.short'    string

# Webhook 日志过滤
_cfg "${CONFIG_WEBHOOK_LOG_FILTER_ENABLED:-}"  '.webhook.webhookLogFilter.enabled'  bool
_cfg "${CONFIG_WEBHOOK_LOG_FILTER_MODE:-}"     '.webhook.webhookLogFilter.mode'     string
_cfg_array "${CONFIG_WEBHOOK_LOG_FILTER_LEVELS-__UNSET__}"    '.webhook.webhookLogFilter.levels'
_cfg_array "${CONFIG_WEBHOOK_LOG_FILTER_KEYWORDS-__UNSET__}"  '.webhook.webhookLogFilter.keywords'

echo "[entrypoint] 配置就绪。"

# ─────────────────────────────────────────────────────────────────────────────
# 5. 若设置 RUN_ON_START=true，则立即执行一次（跳过随机等待）
# ─────────────────────────────────────────────────────────────────────────────
if [ "${RUN_ON_START:-false}" = "true" ]; then
  echo "[entrypoint] 在 $(date) 开始后台初始运行"
  (
    cd /usr/src/microsoft-rewards-script || {
      echo "[entrypoint-bg] 错误: 无法切换到 /usr/src/microsoft-rewards-script 目录" >&2
      exit 1
    }
    # 跳过初始运行的随机延迟，但保留 cron 作业的设置
    SKIP_RANDOM_SLEEP=true scripts/docker/run_daily.sh
    echo "[entrypoint-bg] 初始运行在 $(date) 完成"
  ) &
  echo "[entrypoint] 后台进程已启动 (PID: $!)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 6. 配置并注册 cron 定时任务
# ─────────────────────────────────────────────────────────────────────────────
if [ ! -f /etc/cron.d/microsoft-rewards-cron.template ]; then
  echo "错误: 找不到 cron 模板文件 /etc/cron.d/microsoft-rewards-cron.template" >&2
  exit 1
fi

export TZ
envsubst < /etc/cron.d/microsoft-rewards-cron.template > /etc/cron.d/microsoft-rewards-cron
chmod 0644 /etc/cron.d/microsoft-rewards-cron
crontab /etc/cron.d/microsoft-rewards-cron

echo "[entrypoint] 定时任务已配置 | 计划: $CRON_SCHEDULE | 时区: $TZ | 启动时间: $(date)"

# ─────────────────────────────────────────────────────────────────────────────
# 7. 在前台启动 cron（作为容器主进程 PID 1）
# ─────────────────────────────────────────────────────────────────────────────
exec cron -f
