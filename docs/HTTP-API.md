# LiveContainer HTTP API（v1）

> 本 Fork 内置的 **无依赖** HTTP/1.1 API 服务，基于 Apple `Network.framework` 实现。
> 用途：在 PC / 脚本侧远程完成 **IPA 安装、应用列举、沙箱文件读写** 等操作，无需触碰设备 UI。
>
> 实现位置：
> - `LiveContainerSwiftUI/Services/LCHTTPServer.swift` —— 服务器 / 连接 / 路由 / 鉴权
> - `LiveContainerSwiftUI/Services/LCAppInstallerService.swift` —— 无 UI 安装/卸载管线
> - `LiveContainerSwiftUI/Services/LCSandboxFileManager.swift` —— 沙箱白名单文件访问
> - `LiveContainerSwiftUI/Views/Settings/LCSettingsView.swift` —— 设置界面（开关/端口/Token）

---

## 1. 快速开始

### 1.1 在 App 内启用

`设置 (Settings) → HTTP API`：

| 项 | 说明 | 默认 |
| :--- | :--- | :--- |
| 启用 (Enabled) | 打开后立即启动监听，并持久化 | 关 |
| 端口 (Port) | `1024–65535`，越界回退 8080；修改后自动重启监听 | `8080` |
| 仅回环 (Loopback Only) | 只绑定 `127.0.0.1`（IPv4 回环），局域网不可达 | 关 |
| Token | 32 字节随机数 → **64 位十六进制字符串**，可复制/重新生成 | 首次访问时生成 |

开关状态存放在 App Group UserDefaults：

| Key | 类型 | 含义 |
| :--- | :--- | :--- |
| `LCHTTPServerEnabled` | Bool | 是否自动启动（App 冷启动时读取，见 `LiveContainerSwiftUIApp.swift`） |
| `LCHTTPServerPort` | Int | 端口 |
| `LCHTTPServerLoopbackOnly` | Bool | 仅回环 |
| `LCHTTPServerToken` | String | API Token |

> 端口 / 回环开关变更会触发 `LCHTTPServer.restart()`（先 cancel 旧 listener，0.3s 后重建）。
> App 启动时若 `LCHTTPServerEnabled == true`，会自动 `startIfEnabled()`。

### 1.2 基础调用

```bash
TOKEN="<你的 64 位 hex token>"
BASE="http://192.168.1.23:8080"      # 开了 Loopback Only 就用 http://127.0.0.1:8080

curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/status"
```

---

## 2. 协议约定

### 2.1 传输层限制

| 项 | 行为 |
| :--- | :--- |
| 协议 | **仅 HTTP/1.1**，明文，无 TLS |
| 连接复用 | **不支持 keep-alive**，响应头固定 `Connection: close`，每个请求一条连接 |
| 分块传输 | **不支持** `Transfer-Encoding: chunked` → 返回 `411`，必须带 `Content-Length` |
| 请求头上限 | `16 KiB`（超限 → `431`） |
| 请求体上限（普通路由） | `2 MiB`，超过 → `413`（在内存中缓冲） |
| 请求体上限（流式路由） | 无上限，**边收边落盘**到临时文件（`/tmp/LCUpload_*.tmp`），请求结束即删除 |
| 流式路由白名单 | 仅 `POST /api/v1/apps/install`、`POST /api/v1/fs/upload` |
| 路径前缀 | 所有接口必须以 `/api/v1/` 开头，否则 `404 Unknown endpoint` |

> 流式路由在 **读取第一个 body 字节之前** 就做鉴权：Token 不对时上传不会落盘（省流量 + 避免占盘）。

### 2.2 响应信封

成功（`Content-Type: application/json; charset=utf-8`，键按字典序输出）：

```json
{ "ok": true, "data": { } }
```

失败：

```json
{ "ok": false, "error": "Human readable message" }
```

固定响应头：`Server: LiveContainer`、`Connection: close`、`Content-Length`。

### 2.3 HTTP 状态码

| 码 | 含义 | 典型来源 |
| :--- | :--- | :--- |
| 200 | 成功 | 所有正常返回 |
| 400 | 请求不合法 | 缺参数、非法路径前缀、body 非预期 JSON、IPA 非法、无 .app/Info.plist 不可读、`fs/download` 指向目录 |
| 401 | 鉴权失败 | 缺 Token / Token 错误 |
| 403 | 越权 / 只读 | 路径穿越、软链接逃逸、删改根挂载点、**子容器只读**（`multiLCStatus == 2`）、删除内置 SideStore |
| 404 | 不存在 | 路径不存在、应用不存在、未知端点 |
| 409 | 冲突 | 目标已存在且 `overwrite=false`、安装进行中、容器被其他 LiveContainer 占用 |
| 411 | 缺 Content-Length | 使用了 chunked |
| 413 | body 过大 | 非流式路由 > 2 MiB，或 `Content-Length` 溢出 |
| 431 | 请求头过大 | > 16 KiB |
| 500 | 服务器内部错误 | 签名失败、文件读取失败、JSON 编码失败 |

---

## 3. 鉴权

三种等价写法（常量时间比较，避免时序侧信道）：

| 方式 | 示例 | 适用 |
| :--- | :--- | :--- |
| Bearer | `Authorization: Bearer <token>` | 推荐，所有接口 |
| 自定义头 | `X-LC-Token: <token>` | 所有接口 |
| 查询串 | `?token=<token>` | **仅** `GET /api/v1/fs/download` |

> 之所以给 `fs/download` 开口子，是为了让浏览器 / 下载管理器（如 `wget` 直接跟 URL）可以直接拉文件；
> 其他任何接口把 Token 放 query 都会被判 401。

鉴权判定顺序（`LCHTTPRouter.isAuthorized`）：
1. 读 App Group 里的 `LCHTTPServerToken`，为空 → 直接失败；
2. 依次比对 `Authorization`（兼容无 `Bearer ` 前缀的裸 Token）、`X-LC-Token`；
3. 仅对 `/api/v1/fs/download` 再比对 `?token=`。

> Token 只存在于设备 App Group 与本机请求中，请勿写入版本库或日志。

---

## 4. 接口一览

| 方法 | 路径 | 作用 |
| :--- | :--- | :--- |
| GET | `/api/v1/status` | 服务器与运行环境状态 |
| GET | `/api/v1/apps` | 列举已安装应用 |
| POST | `/api/v1/apps/install` | 安装 IPA（原始 body，流式） |
| POST / DELETE | `/api/v1/apps/uninstall` | 卸载应用 |
| GET | `/api/v1/fs/list` | 列目录 |
| GET | `/api/v1/fs/download` | 下载文件（流式） |
| POST | `/api/v1/fs/upload` | 上传文件（原始 body，流式） |
| POST | `/api/v1/fs/rename` | 重命名 / 移动 |
| POST / DELETE | `/api/v1/fs/delete` | 删除文件或目录 |

---

## 5. 接口详情

### 5.1 `GET /api/v1/status`

返回服务器自身状态与容器环境。

**请求**：无参数。

**响应 `data`**：

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `running` | Bool | listener 是否处于 `.ready` |
| `port` | Int | 当前生效端口 |
| `loopbackOnly` | Bool | 是否仅回环 |
| `multiLCStatus` | Int | `0` = 当前 LC 是主容器；`2` = **子容器（只读，安装/卸载会被拒）** |
| `appCount` | Int | `apps + hiddenApps` 总数 |
| `version` | String | `CFBundleShortVersionString` |

```bash
curl -s -H "X-LC-Token: $TOKEN" "$BASE/api/v1/status"
```
```json
{
  "ok": true,
  "data": {
    "appCount": 12,
    "loopbackOnly": false,
    "multiLCStatus": 0,
    "port": 8080,
    "running": true,
    "version": "2.1.2"
  }
}
```

---

### 5.2 `GET /api/v1/apps`

列举已安装应用（含隐藏应用需显式请求）。

**Query**

| 参数 | 类型 | 默认 | 说明 |
| :--- | :--- | :--- | :--- |
| `includeHidden` | Bool | `false` | 真值：`true` / `1` / `yes`（大小写不敏感） |

**响应 `data.apps[]`**（`LCInstalledAppDTO`）：

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `displayName` | String | 显示名 |
| `bundleIdentifier` | String | Bundle ID |
| `relativeBundlePath` | String | 相对 bundle 路径，如 `com.foo.bar.app`（可在 uninstall 中当标识用） |
| `version` | String | 版本号 |
| `isShared` | Bool | 是否放在共享（App Group）容器 |
| `isHidden` | Bool | 是否隐藏应用 |
| `isJITNeeded` | Bool | 是否已标记需要 JIT |
| `containers` | String[] | 数据容器目录名（Data UUID） |
| `signWarning` | String? | 列表查询恒为 `null`（字段被省略） |

```bash
curl -s -H "Authorization: Bearer $TOKEN" "$BASE/api/v1/apps?includeHidden=1"
```
```json
{
  "ok": true,
  "data": {
    "apps": [
      {
        "bundleIdentifier": "com.example.game",
        "containers": ["2C1F7B6A-...-9F0E"],
        "displayName": "Example Game",
        "isHidden": false,
        "isJITNeeded": true,
        "isShared": false,
        "relativeBundlePath": "com.example.game.app",
        "version": "1.4.0"
      }
    ]
  }
}
```

---

### 5.3 `POST /api/v1/apps/install`

安装 IPA。**body 就是 IPA 原始字节**（不是 multipart），服务端流式落盘后解压、签名、注册。

**Query**

| 参数 | 类型 | 默认 | 说明 |
| :--- | :--- | :--- | :--- |
| `overwrite` | Bool | `false` | 同 Bundle ID 已存在时覆盖（保留原 App 配置：容器/隐藏/共享/JIT 标记/tweak 等） |

**Headers**：`Content-Type: application/octet-stream`（非强制）、**必须** `Content-Length`。

**行为要点**

- 解压到 `tmp/APIInstall_<UUID>/`，找 `Payload/*.app`，读 Info.plist 拿 Bundle ID；
- **`overwrite=false` 且同 ID 已存在**：不报错，改为安装为重命名为 `<bundleId>_<epoch>.app` 的 **第二份副本**；
- **`overwrite=true`**：若被覆盖应用的任一容器正被其他 LiveContainer 实例占用 → `409 Container in use`；
- 安装是**串行**的：并发 install 会得到 `409 Another installation is currently in progress.`；
- `multiLCStatus == 2`（子容器）→ `403`（只读，请在主容器操作）；
- 安装完成后按需签名；**签名失败不会让请求报错**，而是把原因放进返回里的 `signWarning`。

**响应 `data`**：与 `GET /api/v1/apps` 同一 DTO，`signWarning` 有值时表示签名未成功。

```bash
curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/octet-stream" \
  --data-binary @MyApp.ipa \
  "$BASE/api/v1/apps/install?overwrite=true"
```
```json
{
  "ok": true,
  "data": {
    "bundleIdentifier": "com.example.game",
    "containers": [],
    "displayName": "Example Game",
    "isHidden": false,
    "isJITNeeded": false,
    "isShared": false,
    "relativeBundlePath": "com.example.game.app",
    "version": "1.4.0"
  }
}
```

---

### 5.4 `POST` / `DELETE` `/api/v1/apps/uninstall`

卸载应用，可选保留数据。

**标识**（按优先级）：
`?bundleId=` → `?relativeBundlePath=` → body `bundleId` → body `relativeBundlePath`

**参数**

| 参数 | 位置 | 类型 | 默认 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `bundleId` / `relativeBundlePath` | query 或 JSON body | String | — | 必填 |
| `keepData` | query 或 JSON body | Bool | `false` | `false` 时一并删除数据容器与 Keychain 项（**被其他应用共享的容器会跳过**） |

**行为要点**

- 同时从文件夹（`LCFolderManager`）中移除、清理注册的 URL Scheme；
- 容器正被其他 LC 占用 → `409 Container in use`；
- 目标是内置 SideStore（`BuiltInSideStoreAppInfo`）→ `403`；
- 子容器（`multiLCStatus == 2`）→ `403`。

**响应 `data`**：`{ "success": true }`（`path` 为空被省略）。

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"bundleId":"com.example.game","keepData":false}' \
  "$BASE/api/v1/apps/uninstall"
```

---

### 5.5 沙箱虚拟路径系统

所有 `fs/*` 接口使用 **虚拟路径**，只有两个挂载点：

| 虚拟前缀 | 物理位置 | 说明 |
| :--- | :--- | :--- |
| `/private` | `LCPath.docPath` | LiveContainer 自身沙箱 `Documents/`（内含 `Applications/`、`Data/Application/`、`Tweaks/` 等） |
| `/shared` | `LCPath.lcGroupDocPath` | 共享 App Group 下的 `.../LiveContainer/`（无 App Group 时回退到 `docPath`） |

**安全约束**（`LCSandboxFileManager.resolveSafeURL`）

1. 路径必须以 `/private` 或 `/shared` 开头（或其本身），否则 `403 invalidVirtualPath`；
2. 归一化后必须仍在对应根目录内，`..` 逃逸 → `403 accessDeniedPathTraversal`；
3. 父目录 `resolvingSymlinksInPath()` 后若落在根之外 → `403`（容器里存在 `tmp -> 宿主 TMPDIR` 之类的软链）；
4. 软链接指向根之外 → `403 symbolicLinkOutsideRoot`；
5. 根挂载点本身不可删除 / 重命名 / 作为上传目标 → `403 rootModificationForbidden`。

> 跨挂载点移动是允许的（`/private/...` → `/shared/...`），二者都在 App 容器内。

---

### 5.6 `GET /api/v1/fs/list`

列目录（目录优先，其次按 `localizedStandardCompare` 排序）。

**Query**

| 参数 | 说明 |
| :--- | :--- |
| `path` | 必填，如 `/private/Applications`、`/shared/Applications` |

**响应 `data`**

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `path` | String | 回显请求的虚拟路径 |
| `items[]` | Object[] | 目录项（字段见下） |

`items[]`（`LCFileItemDTO`）：

| 字段 | 类型 | 说明 |
| :--- | :--- | :--- |
| `name` | String | 末级名称 |
| `virtualPath` | String | 子项完整虚拟路径，可直接喂给其它接口 |
| `isDirectory` | Bool | 是否目录 |
| `isSymbolicLink` | Bool | 是否软链 |
| `size` | Int64 | 文件大小（字节；目录为 0） |
| `modificationDate` | Double | UNIX 时间戳（秒，含小数） |

```bash
curl -s -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/v1/fs/list?path=/private/Applications"
```
```json
{
  "ok": true,
  "data": {
    "items": [
      {
        "isDirectory": true,
        "isSymbolicLink": false,
        "modificationDate": 1762000000.123,
        "name": "com.example.game.app",
        "size": 0,
        "virtualPath": "/private/Applications/com.example.game.app"
      }
    ],
    "path": "/private/Applications"
  }
}
```

---

### 5.7 `GET /api/v1/fs/download`

下载文件，**流式**（256 KiB 分块）写回，不会把文件读进内存。

**Query**

| 参数 | 说明 |
| :--- | :--- |
| `path` | 必填，文件虚拟路径 |
| `token` | 可选，**仅本接口**允许用查询串鉴权 |

**响应**：`200`，body 为文件原始字节，头为
`Content-Type: application/octet-stream`、`Content-Disposition: attachment; filename="<末级文件名>"`。

**错误**

- 目录 → `400 Path '...' is a directory, not a regular file.`
- 不存在 → `404`
- 根挂载点 → `403`

```bash
# 头鉴权
curl -sL -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/v1/fs/download?path=/private/Applications/com.example.game.app/Info.plist" -o Info.plist

# 直接丢给浏览器 / wget
wget "$BASE/api/v1/fs/download?path=/private/Documents/note.txt&token=$TOKEN"
```

> `downloadFileName` 未做引号转义：文件名内含 `"` 时 `Content-Disposition` 会失真。

---

### 5.8 `POST /api/v1/fs/upload`

上传文件，**body 为原始字节**（流式落盘）。写入策略：先落到临时文件 → 目标已存在则 `replaceItemAt` 原子替换，否则 `moveItem`，中断不会破坏原数据；缺失的中间目录会自动创建。

**Query**

| 参数 | 类型 | 默认 | 说明 |
| :--- | :--- | :--- | :--- |
| `path` | String | — | 必填，目标文件虚拟路径（不可为根） |
| `overwrite` | Bool | `false` | 目标已是**普通文件**时是否覆盖 |

**错误**

- 已存在且 `overwrite=false` → `409 Target already exists ...`
- 目标是目录 → `400 Path '...' is a directory, not a regular file.`
- 根路径 → `403`
- 无 body（未带 `Content-Length`）→ `400 Missing file body`

**响应 `data`**：`{ "success": true, "path": "<目标虚拟路径>" }`

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  --data-binary @payload.txt \
  "$BASE/api/v1/fs/upload?path=/shared/Documents/payload.txt&overwrite=true"
```

---

### 5.9 `POST /api/v1/fs/rename`

重命名 / 移动（含跨挂载点移动）。

**Body**（`application/json`）

| 字段 | 类型 | 必须 | 说明 |
| :--- | :--- | :--- | :--- |
| `from` | String | 是 | 源虚拟路径（不可为根） |
| `to` | String | 是 | 目标虚拟路径（不可为根） |
| `overwrite` | Bool | 否（默认 `false`） | 目标存在时是否先删除 |

**行为要点**

- `from == to` → 幂等成功，不动作；
- 目标在源目录之下（`to` 以 `from + "/"` 开头）→ `403`（拒绝自嵌套移动）；
- 源不存在 → `404`；目标存在且不允许覆盖 → `409`。

**响应 `data`**：`{ "success": true, "path": "<to>" }`

```bash
curl -s -X POST -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"from":"/private/Documents/a.txt","to":"/shared/Documents/a.txt","overwrite":true}' \
  "$BASE/api/v1/fs/rename"
```

---

### 5.10 `POST` / `DELETE` `/api/v1/fs/delete`

删除文件或目录（目录为**递归**删除）。

**Query**

| 参数 | 说明 |
| :--- | :--- |
| `path` | 必填，目标虚拟路径（不可为根） |

**错误**：不存在 → `404`；根挂载点 → `403`；软链接逃逸 → `403`。

**响应 `data`**：`{ "success": true, "path": "<path>" }`

```bash
curl -s -X DELETE -H "Authorization: Bearer $TOKEN" \
  "$BASE/api/v1/fs/delete?path=/private/Documents/old.txt"
```

---

## 6. 端到端示例：一条龙部署

```bash
TOKEN="<token>"; BASE="http://127.0.0.1:8080"
AUTH=(-H "Authorization: Bearer $TOKEN")

# 1) 探活
curl -s "${AUTH[@]}" "$BASE/api/v1/status"

# 2) 推配置文件
curl -s -X POST "${AUTH[@]}" --data-binary @config.plist \
  "$BASE/api/v1/fs/upload?path=/shared/Documents/config.plist&overwrite=true"

# 3) 装包（同名覆盖，保留原配置）
curl -s -X POST "${AUTH[@]}" -H "Content-Type: application/octet-stream" \
  --data-binary @MyApp.ipa "$BASE/api/v1/apps/install?overwrite=true"

# 4) 核对列表
curl -s "${AUTH[@]}" "$BASE/api/v1/apps?includeHidden=1"

# 5) 取回应用数据
curl -sL "${AUTH[@]}" \
  "$BASE/api/v1/fs/download?path=/private/Data/Application/2C1F.../Library/Preferences/x.plist" -o x.plist

# 6) 卸载并清数据
curl -s -X POST "${AUTH[@]}" -H "Content-Type: application/json" \
  -d '{"bundleId":"com.example.game","keepData":false}' "$BASE/api/v1/apps/uninstall"
```

---

## 7. 已知限制与注意事项

1. **无并发多路复用**：每条连接只服务一个请求，响应后立即关闭；客户端请勿复用长连接。
2. **明文传输 + Token 即全部凭据**：Token 泄露等于全量沙箱读写权，只在可信局域网使用。
3. **安装串行**：`LCAppInstallerService` 用单一 `isInstalling` 标志串行化，批量部署请顺序执行（并发会收到 409）。
4. **签名失败不算失败**：`200 + signWarning` 表示包已就位但未签名，终端用户启动时可能被系统拒绝。
5. **`overwrite=false` 不是错误**：同 ID 已存在时会安装成带时间戳后缀的副本，注意别把设备装成"多份同名 App"。
6. **只读模式**：子容器（`multiLCStatus == 2`）下安装/卸载全部 403，需在主容器操作。
7. **`fs/*` 只覆盖 LiveContainer 自身沙箱**（`/private`、`/shared`），不等于能访问被容器化 App 的完整文件系统；各 App 的数据目录位于 `/private/Data/Application/<UUID>/` 或 `/shared/Data/Application/<UUID>/`，可通过 `GET /api/v1/apps` 的 `containers[]` 定位。
8. **上限**：请求头 16 KiB；非流式 body 2 MiB；`install` / `upload` 走流式，不受 2 MiB 限制（但会占用设备可用磁盘）。
9. **一次请求一个响应**：`Content-Length` 与实际 body 不符会被截断或最终收到 `400 Incomplete request body`。

---

## 8. 相关源码索引

| 关注点 | 位置 |
| :--- | :--- |
| 监听 / 端口 / Token 生成 | `LCHTTPServer.swift:46-160` |
| HTTP 解析、流式上传落盘 | `LCHTTPServer.swift:164-534` |
| 路由表 | `LCHTTPServer.swift:581-611` |
| 鉴权（常量时间比较） | `LCHTTPServer.swift:615-652` |
| 错误码映射 | `LCHTTPServer.swift:818-847` |
| 安装 / 卸载管线 | `LCAppInstallerService.swift` |
| 虚拟路径与沙箱白名单 | `LCSandboxFileManager.swift` |
| 设置界面 | `LCSettingsView.swift:170-230` |
| 启动自动拉起 | `LiveContainerSwiftUIApp.swift:102-108` |

---

## 9. 命令行客户端：`lcapi.py`

同目录下的 `lcapi.py` 是**零依赖**（仅 Python 标准库）的 CLI 客户端，把生产环境中踩过的坑都内建了：

| 内建处理 | 原因 |
| :--- | :--- |
| **流式上传/下载**（4 MiB 分块 + 显式 `Content-Length`）| `curl --data-binary` 上传大文件会把整个文件读进内存（实测 23 GB 直接 OOM）；且服务端不支持 chunked，发 chunked 会得到 411 |
| **单请求单连接** | 服务端 `Connection: close`，无 keep-alive |
| **路径 query 编码**（`/` 不编码，`+` 编码为 `%2B`）| 服务端解析 query 时会先把 `+` 替换成空格 |
| **前台检测提示** | App 不在前台时 TCP 能握手但零字节响应，会明确提示而不是干等 |
| **`wait-container` 子命令** | guest app 的 data 容器是**首次启动才惰性创建**的，安装后立刻写 Documents 会找不到路径 |

### 9.1 配置

优先级：**命令行参数 > 环境变量 > `~/.lcapi.json`**

```bash
export LC_HOST=192.168.2.4
export LC_PORT=8888
export LC_TOKEN=<64 位 hex token>
```

或写配置文件：

```json
{ "host": "192.168.2.4", "port": 8888, "token": "<token>" }
```

### 9.2 子命令

| 命令 | 说明 |
| :--- | :--- |
| `status` | 服务器与运行环境状态 |
| `apps [--hidden]` | 列举已安装应用 |
| `container <bundleId> [--documents-only]` | **解析该 App 的容器路径**（root / Documents / Library / tmp）|
| `wait-container <bundleId> [--timeout N]` | 等待 App 首次启动后容器出现（容忍切后台导致的 API 无响应）|
| `ls <vpath>` | 列目录 |
| `install <ipa> [--overwrite]` | 安装 IPA（流式，自动带进度与 ETA）|
| `uninstall <id> [--keep-data] [--path]` | 卸载 |
| `upload <local> <vpath> [--overwrite]` | 上传（流式，支持 20 GB+）|
| `download <vpath> [-o FILE] [--md5]` | 下载（流式；`-o` 省略则仅计算 md5 不落盘）|
| `rm <vpath>` / `mv <src> <dst>` | 删除 / 移动 |
| `verify <local> <vpath>` | **比对本地与远端 md5**（不落盘）|

全局参数：`--host --port --token --timeout --json -q/--quiet --debug --version`

### 9.3 典型工作流：部署带数据包的模拟器类应用

```bash
# 1) 装包
python lcapi.py install "MyApp.ipa"

# 2) 首次启动才生成容器 —— 到设备上启动一次该 App，这边等：
python lcapi.py wait-container com.example.app
#    -> /private/Data/Application/<UUID>/Documents

# 3) 把数据包推入 Documents（20 GB 级别也没问题）
DOCS=$(python lcapi.py container com.example.app --documents-only)
python lcapi.py upload "RomFS.img" "$DOCS/RomFS.img" --overwrite

# 4) 比特级校验（流式下载回读算 md5，不在本地落盘 20 GB）
python lcapi.py verify "RomFS.img" "$DOCS/RomFS.img"
```

### 9.4 退出码

| 码 | 含义 |
| :--- | :--- |
| 0 | 成功 |
| 1 | 服务端返回业务错误（含 4xx/5xx 的 `error` 字段）|
| 2 | 用法/配置错误（缺 host、缺 token、未知命令）|
| 3 | `container` 尚未创建 / `wait-container` 超时 |
| 4 | 连接失败（端口未监听、地址不可达、App 不在前台）|
| 5 | `verify` md5 不一致 |
| 130 | 用户中断 |

