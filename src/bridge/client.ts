/**
 * WebSocket client for the Godot MCP Bridge addon.
 *
 * The addon listens on 127.0.0.1 (editor: 6510, running game: 6511) and only
 * accepts connections that present the token stored in
 * <project>/.godot/mcp_bridge_token.
 */

import { existsSync, readFileSync, realpathSync } from 'fs';
import { join, resolve } from 'path';

// Node 22+ ships a global WebSocket, but @types/node 20 doesn't declare it.
declare const WebSocket: any;

export const EDITOR_PORT = 6510;
export const GAME_PORT = 6511;

export class BridgeError extends Error {}

export function normalizeProjectPath(projectPath: string): string {
  const absolute = resolve(projectPath);
  const real = existsSync(absolute) ? realpathSync(absolute) : absolute;
  return real.replace(/[\\/]+$/, '');
}

export function readBridgeToken(projectPath: string): string | null {
  const tokenPath = join(projectPath, '.godot', 'mcp_bridge_token');
  if (!existsSync(tokenPath)) return null;
  const token = readFileSync(tokenPath, 'utf8').trim();
  return token.length >= 32 ? token : null;
}

interface Pending {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
  socket: any;
}

export class BridgeConnection {
  private ws: any = null;
  private project: string | null = null;
  private info: any = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();

  constructor(readonly kind: 'editor' | 'game', readonly port: number) {}

  private isOpen(): boolean {
    return this.ws !== null && this.ws.readyState === 1;
  }

  /** Connects (or reuses the connection) and returns the bridge's hello info. */
  async connect(projectPath: string, waitMs = 0): Promise<any> {
    const project = normalizeProjectPath(projectPath);
    if (this.isOpen() && this.project === project) return this.info;
    const deadline = Date.now() + waitMs;
    for (;;) {
      try {
        return await this.connectOnce(project);
      } catch (error) {
        // Wrong project or bad token won't fix itself by retrying.
        if (error instanceof BridgeError && /token|different project/i.test(error.message)) throw error;
        if (Date.now() >= deadline) throw error;
        await new Promise((r) => setTimeout(r, 300));
      }
    }
  }

  private async connectOnce(project: string): Promise<any> {
    this.close();
    const token = readBridgeToken(project);
    if (!token) {
      throw new BridgeError(
        `No bridge token in ${project}/.godot. Run bridge_install, then open the editor or run the game once.`
      );
    }
    const ws = new WebSocket(`ws://127.0.0.1:${this.port}`);
    await new Promise<void>((res, rej) => {
      const timer = setTimeout(() => rej(this.unreachable()), 3000);
      ws.onopen = () => {
        clearTimeout(timer);
        res();
      };
      ws.onerror = () => {
        clearTimeout(timer);
        rej(this.unreachable());
      };
    });
    ws.onmessage = (event: any) => this.onMessage(String(event.data));
    ws.onclose = () => {
      if (this.ws === ws) {
        this.ws = null;
        this.info = null;
      }
      for (const [id, p] of this.pending) {
        if (p.socket !== ws) continue;
        clearTimeout(p.timer);
        p.reject(new BridgeError(`Connection to the Godot ${this.kind} closed`));
        this.pending.delete(id);
      }
    };
    ws.onerror = () => {};
    this.ws = ws;
    this.project = project;

    const info = await this.request('auth', { token }, 5000);
    if (normalizeProjectPath(String(info.project_path ?? '')) !== project) {
      this.close();
      throw new BridgeError(
        `The Godot ${this.kind} on port ${this.port} has a different project open: ${info.project_path}`
      );
    }
    this.info = info;
    return info;
  }

  private unreachable(): BridgeError {
    return new BridgeError(
      this.kind === 'editor'
        ? `Can't reach the Godot editor bridge on 127.0.0.1:${this.port}. Is the editor open with the "Godot MCP Bridge" plugin enabled?`
        : `Can't reach the running game on 127.0.0.1:${this.port}. Start it with editor_play or run_project (the bridge autoload must be enabled).`
    );
  }

  private onMessage(text: string) {
    let msg: any;
    try {
      msg = JSON.parse(text);
    } catch {
      return;
    }
    const pending = this.pending.get(msg.id);
    if (!pending) return;
    this.pending.delete(msg.id);
    clearTimeout(pending.timer);
    if (msg.error) pending.reject(new BridgeError(msg.error.message ?? 'Unknown bridge error'));
    else pending.resolve(msg.result);
  }

  private request(method: string, params: object, timeoutMs: number): Promise<any> {
    if (!this.isOpen()) return Promise.reject(this.unreachable());
    const id = this.nextId++;
    return new Promise((res, rej) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        rej(new BridgeError(`${method} timed out after ${timeoutMs} ms`));
      }, timeoutMs);
      this.pending.set(id, { resolve: res, reject: rej, timer, socket: this.ws });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  async call(projectPath: string, method: string, params: object, options: { waitMs?: number; timeoutMs?: number } = {}) {
    await this.connect(projectPath, options.waitMs ?? 0);
    return this.request(method, params, options.timeoutMs ?? 30000);
  }

  close() {
    if (this.ws) {
      try {
        this.ws.close();
      } catch {
        // already closed
      }
    }
    this.ws = null;
    this.info = null;
  }
}
