#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
lcapi.py —— LiveContainer HTTP API 命令行客户端

只依赖 Python 标准库（http.client / hashlib / argparse），跨 Windows / macOS / Linux。

设计缘由（都是实测踩过的坑）：
  1. curl --data-binary 上传 >1GB 文件会 OOM，必须自己流式发送并显式设置
     Content-Length（服务端不支持 chunked，发 chunked 会得到 411）。
  2. 服务端对每个请求都用新连接（Connection: close，无 keep-alive），
     所以这里每次请求都新建 HTTPConnection。
  3. 服务端 query 解析会先把 "+" 替换成空格，所以路径里的 "+" 必须编码成 %2B。
  4. 应用不在前台时 TCP 能握手但不回任何数据，表现为"假死"；本工具会在
     超时后给出明确提示，而不是干等。
  5. guest app 的 data 容器是首次启动才惰性创建的，安装后立刻去写 Documents
     会找不到路径 —— 因此提供 wait-container 子命令。

用法示例：
  export LC_TOKEN=xxxxxxxx
  python lcapi.py --host 192.168.2.4 --port 8888 status
  python lcapi.py apps --hidden
  python lcapi.py container org.nxnative.0400c3f00006e000
  python lcapi.py wait-container org.nxnative.0400c3f00006e000
  python lcapi.py ls /private/Applications
  python lcapi.py install MyApp.ipa --overwrite
  python lcapi.py upload RomFS.img "/private/Data/Application/<UUID>/Documents/RomFS.img"
  python lcapi.py download "/shared/a.bin" -o a.bin
  python lcapi.py verify RomFS.img "/private/Data/Application/<UUID>/Documents/RomFS.img"
  python lcapi.py mv /shared/a.bin /shared/b.bin
  python lcapi.py rm /shared/b.bin

配置优先级：命令行参数 > 环境变量(LC_HOST/LC_PORT/LC_TOKEN) > ~/.lcapi.json
"""

import argparse
import hashlib
import http.client
import json
import os
import posixpath
import socket
import sys
import time
import urllib.parse

# Windows 控制台默认 cp936，遇到中文文件名会炸；统一改成 utf-8
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass

__version__ = "1.0.0"

CHUNK = 4 * 1024 * 1024          # 流式读写的分块大小
PROGRESS_EVERY = 5.0             # 进度刷新间隔（秒）
CONFIG_PATH = os.path.join(os.path.expanduser("~"), ".lcapi.json")


# --------------------------------------------------------------------------- #
# 异常与输出
# --------------------------------------------------------------------------- #

class LCError(Exception):
    """服务端返回的错误，或传输层错误。"""


class SilentTimeout(LCError):
    """TCP 连上了但服务端零字节响应 —— 通常是 App 不在前台。"""


class ConnError(LCError):
    """连不上：端口未监听 / 地址不可达。"""


def eprint(*a, **kw):
    print(*a, file=sys.stderr, **kw)


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if n < 1024 or unit == "TiB":
            return "%.2f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def human_time(sec):
    sec = int(max(0, sec))
    h, rem = divmod(sec, 3600)
    m, s = divmod(rem, 60)
    return ("%d:%02d:%02d" % (h, m, s)) if h else ("%d:%02d" % (m, s))


class Progress:
    """单行刷新的进度条；非 TTY 或 --quiet 时静默。"""

    def __init__(self, label, total, enabled=True):
        self.label = label
        self.total = total
        self.enabled = enabled and sys.stderr.isatty()
        self.t0 = time.time()
        self.last = 0.0
        self.done = 0

    def update(self, done):
        self.done = done
        if not self.enabled:
            return
        now = time.time()
        if now - self.last < 0.2 and done < self.total:
            return
        self.last = now
        el = max(now - self.t0, 1e-9)
        rate = done / el
        pct = (done * 100.0 / self.total) if self.total else 100.0
        eta = (self.total - done) / rate if rate > 0 and self.total else 0
        width = 24
        fill = int(width * pct / 100)
        bar = "#" * fill + "-" * (width - fill)
        sys.stderr.write("\r  %s [%s] %5.1f%%  %s/%s  %s/s  eta %s   " % (
            self.label, bar, pct, human(done), human(self.total),
            human(int(rate)), human_time(eta)))
        sys.stderr.flush()

    def finish(self):
        if not self.enabled:
            return
        el = max(time.time() - self.t0, 1e-9)
        sys.stderr.write("\r  %s done: %s in %s (%s/s)%s\n" % (
            self.label, human(self.done), human_time(el),
            human(int(self.done / el)), " " * 20))
        sys.stderr.flush()

    def clear(self):
        if not self.enabled:
            return
        sys.stderr.write("\r" + " " * 100 + "\r")
        sys.stderr.flush()


# --------------------------------------------------------------------------- #
# 客户端
# --------------------------------------------------------------------------- #

class LCClient:
    def __init__(self, host, port, token, timeout=60, quiet=False, debug=False):
        self.host = host
        self.port = int(port)
        self.token = token
        self.timeout = float(timeout)
        self.quiet = quiet
        self.debug = debug

    # -- 底层 -------------------------------------------------------------- #

    def _conn(self, timeout=None):
        return http.client.HTTPConnection(
            self.host, self.port, timeout=timeout or self.timeout)

    @staticmethod
    def _q(path, query):
        """把 query 拼成 URL；'/' 不编码以便可读，'+' 会被服务端当作空格故必须编码。"""
        url = path
        if query:
            pairs = []
            for k, v in query.items():
                if v is None:
                    continue
                if isinstance(v, bool):
                    v = "true" if v else "false"
                pairs.append("%s=%s" % (
                    urllib.parse.quote(str(k), safe=""),
                    urllib.parse.quote(str(v), safe="/")))
            url += "?" + "&".join(pairs)
        return url

    def _headers(self, extra=None, auth=True):
        h = {}
        if auth and self.token:
            h["Authorization"] = "Bearer " + self.token
        if extra:
            h.update(extra)
        return h

    def request(self, method, path, query=None, body=None, raw=False,
                timeout=None, auth=True, query_token=False):
        """普通（非流式）请求。返回解析后的 dict，或 raw=True 时返回 bytes。"""
        url = self._q(path, query)
        if query_token and self.token:
            url += ("&" if "?" in url else "?") + "token=" + \
                   urllib.parse.quote(self.token, safe="")
        if self.debug:
            eprint("[debug] %s %s" % (method, url))

        conn = self._conn(timeout)
        try:
            conn.putrequest(method, url)
            for k, v in self._headers(auth=auth).items():
                conn.putheader(k, v)
            if body is None:
                conn.endheaders()
            else:
                conn.putheader("Content-Type", "application/octet-stream")
                conn.putheader("Content-Length", str(len(body)))
                conn.endheaders()
                conn.send(body)
            try:
                resp = conn.getresponse()
            except (socket.timeout, TimeoutError) as exc:
                raise SilentTimeout(self._hint(exc))
            data = resp.read()
            status = resp.status
        except (ConnectionRefusedError, socket.gaierror, ConnectionResetError,
                BrokenPipeError, OSError) as exc:
            raise self._conn_error(exc)
        finally:
            conn.close()

        if not data:
            raise SilentTimeout(self._hint(None))
        if raw:
            if status != 200:
                raise LCError(self._extract_error(data) or "HTTP %d" % status)
            return data

        try:
            obj = json.loads(data.decode("utf-8"))
        except Exception:
            raise LCError("非 JSON 响应 (HTTP %d): %s" % (
                status, data[:200].decode("utf-8", "replace")))
        if not obj.get("ok", False):
            raise LCError(obj.get("error") or "HTTP %d" % status)
        return obj.get("data")

    @staticmethod
    def _extract_error(data):
        try:
            return json.loads(data.decode("utf-8")).get("error")
        except Exception:
            return None

    @staticmethod
    def _hint(exc):
        base = "服务端零响应/传输中断"
        if exc:
            base += " (%s)" % exc
        return (base + "\n  提示：TCP 能连上却不回数据，通常是 LiveContainer 不在前台。"
                "请把 App 切到前台再试。")

    def _conn_error(self, exc):
        msg = str(exc) or exc.__class__.__name__
        return ConnError(
            "无法连接 %s:%s (%s)\n  提示：端口未监听 / 地址不对 / 设备离线。"
            "请确认 LiveContainer 正在前台运行，且 HTTP API 已启用。"
            % (self.host, self.port, msg))

    # -- 流式 -------------------------------------------------------------- #

    def _send_head(self, conn, method, url, extra_headers=None, length=None):
        """发出请求行/请求头，把连接类错误统一转成 ConnError。"""
        try:
            conn.putrequest(method, url)
            for k, v in self._headers().items():
                conn.putheader(k, v)
            for k, v in (extra_headers or {}).items():
                conn.putheader(k, v)
            if length is not None:
                conn.putheader("Content-Length", str(length))
            conn.endheaders()
        except (ConnectionRefusedError, socket.gaierror, ConnectionResetError,
                BrokenPipeError, OSError) as exc:
            raise self._conn_error(exc)

    def stream_upload(self, local_path, vpath, overwrite=False, progress=True):
        """流式上传本地文件到虚拟路径。显式带 Content-Length，绝不发 chunked。"""
        size = os.path.getsize(local_path)
        url = self._q("/api/v1/fs/upload",
                      {"path": vpath, "overwrite": "true" if overwrite else "false"})
        conn = self._conn(timeout=7200)
        try:
            self._send_head(conn, "POST", url,
                            {"Content-Type": "application/octet-stream"},
                            length=size)

            pg = Progress("upload", size, progress and not self.quiet)
            sent = 0
            try:
                with open(local_path, "rb") as f:
                    while True:
                        buf = f.read(CHUNK)
                        if not buf:
                            break
                        conn.send(buf)
                        sent += len(buf)
                        pg.update(sent)
            except (ConnectionResetError, BrokenPipeError, OSError) as exc:
                pg.clear()
                raise self._conn_error(exc)
            pg.finish()

            try:
                resp = conn.getresponse()
            except (socket.timeout, TimeoutError) as exc:
                pg.clear()
                raise SilentTimeout(self._hint(exc))
            except (ConnectionRefusedError, socket.gaierror,
                    ConnectionResetError, BrokenPipeError, OSError) as exc:
                pg.clear()
                raise self._conn_error(exc)
            data = resp.read()
            status = resp.status
            if sent != size:
                raise LCError("本地读取字节数异常: %d != %d" % (sent, size))
            if not data:
                raise SilentTimeout(self._hint(None))
            obj = json.loads(data.decode("utf-8"))
            if not obj.get("ok"):
                raise LCError(obj.get("error") or "HTTP %d" % status)
            return obj.get("data")
        finally:
            conn.close()

    def stream_download(self, vpath, out_path=None, progress=True,
                        hash_md5=False, use_query_token=True):
        """
        流式下载。out_path 为 None 时不落盘（仅计算 md5 / 丢弃）。
        返回 (bytes_received, md5hex_or_None)。
        """
        # 该端点是唯一允许 query token 的接口，但优先用请求头（避免 token
        # 出现在 URL / 浏览器历史 / 日志里）。use_query_token=True 时改用 query。
        query = {"path": vpath}
        if use_query_token and self.token:
            query["token"] = self.token
        url = self._q("/api/v1/fs/download", query)
        conn = self._conn(timeout=7200)
        h = hashlib.md5() if hash_md5 else None
        received = 0
        try:
            self._send_head(conn, "GET", url, length=None)
            try:
                resp = conn.getresponse()
            except (socket.timeout, TimeoutError) as exc:
                raise SilentTimeout(self._hint(exc))
            except (ConnectionRefusedError, socket.gaierror,
                    ConnectionResetError, BrokenPipeError, OSError) as exc:
                raise self._conn_error(exc)

            declared = resp.getheader("Content-Length")
            declared = int(declared) if declared and declared.isdigit() else 0

            if resp.status != 200:
                data = resp.read()
                raise LCError(self._extract_error(data) or "HTTP %d" % resp.status)

            pg = Progress("download", declared, progress and not self.quiet)
            out = open(out_path, "wb") if out_path else None
            try:
                while True:
                    buf = resp.read(CHUNK)
                    if not buf:
                        break
                    received += len(buf)
                    if out:
                        out.write(buf)
                    if h:
                        h.update(buf)
                    pg.update(received)
                pg.finish()
            finally:
                if out:
                    out.close()
            if declared and received != declared:
                raise LCError("下载不完整: 收到 %d / 声明 %d 字节" % (received, declared))
            return received, (h.hexdigest() if h else None)
        finally:
            conn.close()

    # -- 便捷方法 ---------------------------------------------------------- #

    def status(self):
        return self.request("GET", "/api/v1/status")

    def apps(self, include_hidden=False):
        return self.request("GET", "/api/v1/apps",
                            {"includeHidden": "true" if include_hidden else None})

    def list_dir(self, vpath):
        return self.request("GET", "/api/v1/fs/list", {"path": vpath})

    def delete(self, vpath):
        return self.request("DELETE", "/api/v1/fs/delete", {"path": vpath})

    def rename(self, src, dst, overwrite=False):
        body = json.dumps({"from": src, "to": dst,
                           "overwrite": bool(overwrite)}).encode("utf-8")
        url = self._q("/api/v1/fs/rename", None)
        conn = self._conn()
        try:
            self._send_head(conn, "POST", url, {"Content-Type": "application/json"},
                            length=len(body))
            conn.send(body)
            resp = conn.getresponse()
            data = resp.read()
        except (ConnectionRefusedError, socket.gaierror, ConnectionResetError,
                BrokenPipeError, socket.timeout, TimeoutError, OSError) as exc:
            raise self._conn_error(exc)
        finally:
            conn.close()
        if not data:
            raise SilentTimeout(self._hint(None))
        obj = json.loads(data.decode("utf-8"))
        if not obj.get("ok"):
            raise LCError(obj.get("error") or "HTTP %d" % resp.status)
        return obj.get("data")

    def find_app(self, bundle_id):
        for a in self.apps(include_hidden=True)["apps"]:
            if a["bundleIdentifier"] == bundle_id or \
               a["relativeBundlePath"] == bundle_id:
                return a
        return None

    def container_paths(self, bundle_id):
        """返回该 App 的容器虚拟路径列表（不是所有 App 都有容器）。"""
        app = self.find_app(bundle_id)
        if not app:
            raise LCError("应用未安装: %s" % bundle_id)
        out = []
        for fn in app.get("containers") or []:
            root = ("/shared/Data/Application/" if app.get("isShared")
                    else "/private/Data/Application/") + fn
            out.append({
                "folderName": fn,
                "root": root,
                "documents": posixpath.join(root, "Documents"),
                "library": posixpath.join(root, "Library"),
                "tmp": posixpath.join(root, "tmp"),
            })
        return out


# --------------------------------------------------------------------------- #
# CLI
# --------------------------------------------------------------------------- #

def load_config(args):
    cfg = {}
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                cfg = json.load(f)
        except Exception as e:
            eprint("警告: 无法读取 %s (%s)" % (CONFIG_PATH, e))
    host = args.host or os.environ.get("LC_HOST") or cfg.get("host")
    port = args.port or os.environ.get("LC_PORT") or cfg.get("port") or 8080
    token = args.token or os.environ.get("LC_TOKEN") or cfg.get("token")
    return host, port, token


def needs_token(args):
    return args.cmd in {
        "status", "apps", "ls", "container", "wait-container", "install",
        "uninstall", "upload", "download", "rm", "mv", "verify",
    }


def eprint_table(rows, headers):
    widths = [len(h) for h in headers]
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], len(str(c)))
    line = "  ".join(h.ljust(widths[i]) for i, h in enumerate(headers))
    print(line)
    print("  ".join("-" * w for w in widths))
    for r in rows:
        print("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(r)))


def main():
    p = argparse.ArgumentParser(
        prog="lcapi",
        description="LiveContainer HTTP API 客户端（流式上传/下载，支持 >20GB 大文件）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("用法示例：")[-1])
    p.add_argument("--host", help="设备地址，如 192.168.2.4（或 LC_HOST）")
    p.add_argument("--port", type=int, help="端口，默认 8080（或 LC_PORT）")
    p.add_argument("--token", help="API Token（或 LC_TOKEN）")
    p.add_argument("--timeout", type=float, default=60, help="普通请求超时秒数，默认 60")
    p.add_argument("--json", action="store_true", help="以原始 JSON 输出（便于管道处理）")
    p.add_argument("-q", "--quiet", action="store_true", help="不显示进度条")
    p.add_argument("--debug", action="store_true", help="打印请求行")
    p.add_argument("--version", action="version", version="lcapi " + __version__)

    sub = p.add_subparsers(dest="cmd", metavar="<命令>")

    sub.add_parser("status", help="服务器与运行环境状态")

    sp = sub.add_parser("apps", help="列举已安装应用")
    sp.add_argument("--hidden", action="store_true", help="包含隐藏应用")

    sp = sub.add_parser("container", help="解析某 App 的容器路径（含 Documents）")
    sp.add_argument("bundle_id")
    sp.add_argument("--documents-only", action="store_true", help="只输出 Documents 路径")

    sp = sub.add_parser("wait-container", help="等待 App 首次启动后容器创建（期间 API 可能短暂无响应）")
    sp.add_argument("bundle_id")
    sp.add_argument("--timeout", type=float, default=600, help="最长等待秒数，默认 600")
    sp.add_argument("--interval", type=float, default=5, help="轮询间隔秒数，默认 5")

    sp = sub.add_parser("ls", help="列目录")
    sp.add_argument("path")

    sp = sub.add_parser("install", help="安装 IPA（大文件自动流式）")
    sp.add_argument("ipa")
    sp.add_argument("--overwrite", action="store_true",
                    help="同 Bundle ID 已存在时覆盖（保留原容器/设置）")

    sp = sub.add_parser("uninstall", help="卸载应用")
    sp.add_argument("id", help="Bundle ID 或相对 bundle 路径")
    sp.add_argument("--keep-data", action="store_true", help="保留数据容器与 Keychain")
    sp.add_argument("--path", action="store_true", help="把 id 当作 relativeBundlePath 传")

    sp = sub.add_parser("upload", help="上传本地文件到虚拟路径（流式）")
    sp.add_argument("local")
    sp.add_argument("vpath")
    sp.add_argument("--overwrite", action="store_true")

    sp = sub.add_parser("download", help="下载虚拟路径文件（流式）")
    sp.add_argument("vpath")
    sp.add_argument("-o", "--out", help="输出文件；省略则仅计算/丢弃")
    sp.add_argument("--md5", action="store_true", help="同时输出 md5")

    sp = sub.add_parser("rm", help="删除文件或目录（目录递归）")
    sp.add_argument("vpath")

    sp = sub.add_parser("mv", help="重命名 / 移动")
    sp.add_argument("src")
    sp.add_argument("dst")
    sp.add_argument("--overwrite", action="store_true")

    sp = sub.add_parser("verify", help="比对本地文件与远端文件的 md5")
    sp.add_argument("local")
    sp.add_argument("vpath")

    args = p.parse_args()
    if not args.cmd:
        p.print_help()
        return 2

    host, port, token = load_config(args)
    if not host:
        eprint("错误: 未指定 --host（也没有 LC_HOST / ~/.lcapi.json）")
        return 2
    if needs_token(args) and not token:
        eprint("错误: 未指定 --token（也没有 LC_TOKEN / ~/.lcapi.json）")
        return 2

    c = LCClient(host, port, token, timeout=args.timeout,
                 quiet=args.quiet, debug=args.debug)

    try:
        return dispatch(c, args)
    except SilentTimeout as e:
        eprint("连接失败: %s" % e)
        return 4
    except ConnError as e:
        eprint("连接失败: %s" % e)
        return 4
    except (ConnectionRefusedError, socket.gaierror, ConnectionResetError,
            BrokenPipeError, socket.timeout, TimeoutError) as e:
        eprint("连接失败: %s" % c._conn_error(e))
        return 4
    except OSError as e:
        eprint("网络错误: %s" % e)
        return 4
    except LCError as e:
        eprint("错误: %s" % e)
        return 1
    except KeyboardInterrupt:
        eprint("\n已中断")
        return 130


def dispatch(c, args):
    cmd = args.cmd

    if cmd == "status":
        d = c.status()
        if args.json:
            print(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True))
        else:
            for k in sorted(d):
                print("%-16s %s" % (k, d[k]))
        return 0

    if cmd == "apps":
        d = c.apps(include_hidden=args.hidden)
        if args.json:
            print(json.dumps(d, ensure_ascii=False, indent=2))
            return 0
        rows = [[a["displayName"], a["bundleIdentifier"], a["version"],
                 len(a.get("containers") or []),
                 "shared" if a.get("isShared") else "-",
                 "hidden" if a.get("isHidden") else "-",
                 "jit" if a.get("isJITNeeded") else "-"]
                for a in d["apps"]]
        eprint_table(rows, ["Name", "BundleID", "Version", "Ctr", "Shared", "Hidden", "JIT"])
        eprint("\n共 %d 个应用" % len(rows))
        return 0

    if cmd == "container":
        conts = c.container_paths(args.bundle_id)
        if not conts:
            eprint("错误: %s 还没有容器（首次启动该 App 后才会创建）"
                   "\n  可先运行: lcapi wait-container %s" % (args.bundle_id, args.bundle_id))
            return 3
        if args.documents_only:
            for x in conts:
                print(x["documents"])
            return 0
        if args.json:
            print(json.dumps(conts, ensure_ascii=False, indent=2))
            return 0
        for x in conts:
            print("容器      %s" % x["folderName"])
            print("  根       %s" % x["root"])
            print("  Documents %s" % x["documents"])
            print("  Library   %s" % x["library"])
            print("  tmp       %s" % x["tmp"])
        return 0

    if cmd == "wait-container":
        t0 = time.time()
        errs = 0
        while time.time() - t0 < args.timeout:
            try:
                conts = c.container_paths(args.bundle_id)
                if conts:
                    print(conts[0]["documents"])
                    return 0
                errs = 0
            except SilentTimeout:
                # App 切后台时 API 会短暂无响应，忽略继续等
                errs += 1
            except LCError as e:
                if "未安装" in str(e):
                    raise
            time.sleep(args.interval)
        eprint("超时: %g 秒内未检测到容器（API 无响应 %d 次）" % (args.timeout, errs))
        return 3

    if cmd == "ls":
        d = c.list_dir(args.path)
        if args.json:
            print(json.dumps(d, ensure_ascii=False, indent=2))
            return 0
        rows = []
        for i in d["items"]:
            kind = "DIR " if i["isDirectory"] else ("LINK" if i.get("isSymbolicLink") else "file")
            size = "" if i["isDirectory"] else human(i["size"])
            rows.append([kind, size, i["name"], i["virtualPath"]])
        eprint_table(rows, ["Type", "Size", "Name", "VirtualPath"])
        eprint("\n共 %d 项" % len(rows))
        return 0

    if cmd == "install":
        size = os.path.getsize(args.ipa)
        eprint("安装 %s (%s)" % (os.path.basename(args.ipa), human(size)))
        if not c.quiet:
            eprint("注: 上传+解压+签名期间设备无输出属正常，请勿中断")
        url = c._q("/api/v1/apps/install",
                   {"overwrite": "true" if args.overwrite else None})
        conn = c._conn(timeout=7200)
        try:
            c._send_head(conn, "POST", url,
                         {"Content-Type": "application/octet-stream"}, length=size)
            pg = Progress("install", size, not c.quiet)
            sent = 0
            try:
                with open(args.ipa, "rb") as f:
                    while True:
                        buf = f.read(CHUNK)
                        if not buf:
                            break
                        conn.send(buf)
                        sent += len(buf)
                        pg.update(sent)
            except (ConnectionResetError, BrokenPipeError, OSError) as exc:
                pg.clear()
                raise c._conn_error(exc)
            pg.finish()
            resp = conn.getresponse()
            data = resp.read()
        finally:
            conn.close()
        if not data:
            raise SilentTimeout(c._hint(None))
        obj = json.loads(data.decode("utf-8"))
        if not obj.get("ok"):
            raise LCError(obj.get("error") or "HTTP %d" % resp.status)
        d = obj.get("data") or {}
        print("已安装: %s (%s) v%s" % (d.get("displayName"),
                                      d.get("bundleIdentifier"), d.get("version")))
        if d.get("signWarning"):
            eprint("警告: 签名未成功 -> %s" % d["signWarning"])
            eprint("  包已就位但未签名，设备上可能无法启动。")
        print("相对路径: %s" % d.get("relativeBundlePath"))
        return 0

    if cmd == "uninstall":
        key = "relativeBundlePath" if args.path else "bundleId"
        body = json.dumps({key: args.id, "keepData": bool(args.keep_data)}).encode()
        conn = c._conn()
        try:
            c._send_head(conn, "POST", "/api/v1/apps/uninstall",
                         {"Content-Type": "application/json"}, length=len(body))
            conn.send(body)
            resp = conn.getresponse()
            data = resp.read()
        finally:
            conn.close()
        if not data:
            raise SilentTimeout(c._hint(None))
        obj = json.loads(data.decode("utf-8"))
        if not obj.get("ok"):
            raise LCError(obj.get("error") or "HTTP %d" % resp.status)
        print("已卸载: %s%s" % (args.id, "（已保留数据）" if args.keep_data else ""))
        return 0

    if cmd == "upload":
        size = os.path.getsize(args.local)
        eprint("上传 %s (%s) -> %s" % (os.path.basename(args.local), human(size), args.vpath))
        d = c.stream_upload(args.local, args.vpath, args.overwrite, not args.quiet)
        if args.json:
            print(json.dumps(d, ensure_ascii=False, indent=2))
        else:
            print("完成: %s" % (d or {}).get("path", args.vpath))
        return 0

    if cmd == "download":
        n, md5 = c.stream_download(args.vpath, args.out, not args.quiet,
                                   hash_md5=args.md5 or not args.out)
        if args.json:
            print(json.dumps({"bytes": n, "md5": md5, "out": args.out}))
        else:
            print("完成: %s 字节 (%s)%s" % (
                n, human(n), ("\nmd5: %s" % md5) if md5 else ""))
        return 0

    if cmd == "rm":
        c.delete(args.vpath)
        print("已删除: %s" % args.vpath)
        return 0

    if cmd == "mv":
        c.rename(args.src, args.dst, args.overwrite)
        print("已移动: %s -> %s" % (args.src, args.dst))
        return 0

    if cmd == "verify":
        lsize = os.path.getsize(args.local)
        eprint("校验 %s (%s)" % (os.path.basename(args.local), human(lsize)))
        h = hashlib.md5()
        pg = Progress("local", lsize, not c.quiet)
        read = 0
        with open(args.local, "rb") as f:
            while True:
                b = f.read(CHUNK)
                if not b:
                    break
                h.update(b)
                read += len(b)
                pg.update(read)
        pg.finish()
        lmd5 = h.hexdigest()

        n, rmd5 = c.stream_download(args.vpath, None, not c.quiet, hash_md5=True)
        print("local  md5 = %s  (%d bytes)" % (lmd5, lsize))
        print("remote md5 = %s  (%d bytes)" % (rmd5, n))
        if lmd5 == rmd5 and lsize == n:
            print("VERDICT: MATCH - 文件完整")
            return 0
        print("VERDICT: MISMATCH - 文件不一致!")
        return 5

    eprint("未知命令: %s" % cmd)
    return 2


if __name__ == "__main__":
    sys.exit(main())
