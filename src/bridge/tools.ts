/**
 * MCP tools backed by the Godot MCP Bridge addon: live editor control,
 * project settings, and screenshots/input/inspection of the running game.
 */

import { cpSync, existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'fs';
import { randomBytes } from 'crypto';
import { join } from 'path';
import { execFile } from 'child_process';
import { promisify } from 'util';

import { BridgeConnection, BridgeError, EDITOR_PORT, GAME_PORT, normalizeProjectPath, readBridgeToken } from './client.js';

const execFileAsync = promisify(execFile);

const ADDON_RES_DIR = 'res://addons/godot_mcp_bridge';

export interface BridgeContext {
  /** Resolves the Godot executable, or null if none was found. */
  getGodotPath(): Promise<string | null>;
  /** Directory of the addon shipped with this server. */
  addonSource: string;
}

type Target = 'editor' | 'game' | 'project';

interface ToolSpec {
  name: string;
  description: string;
  properties?: Record<string, any>;
  required?: string[];
  target?: Target;
  method?: string;
}

const PROJECT_PATH = {
  type: 'string',
  description: 'Godot project directory. Optional when the GODOT_MCP_PROJECT environment variable is set.',
};
const WAIT_MS = {
  type: 'number',
  description: 'How long to keep retrying the connection, in ms (useful right after launching the editor or game).',
};
const NODE = (what = 'Node path') => ({ type: 'string', description: what });
const PROPERTIES = {
  type: 'object',
  description:
    'Property name -> value. Values are converted to the property type: "Vector2(1, 2)", [1, 2] or {"x":1,"y":2} for vectors; "#ff0000" or "red" for colors; "res://..." for resources. Sub-properties like "position:x" work too.',
};
const MAX_WIDTH = { type: 'number', description: 'Downscale the image to at most this width (default 1280).' };
const PROPS_LIST = { type: 'array', items: { type: 'string' }, description: 'Extra properties to include for every node.' };

const EDITOR_NODE = 'Node path relative to the edited scene root ("." is the root)';
const GAME_NODE = 'Absolute path ("/root/Main/Player") or path relative to the current scene ("Player")';

const SPECS: ToolSpec[] = [
  {
    name: 'bridge_install',
    description:
      'Install or update the Godot MCP Bridge addon in a project and enable it (editor plugin + runtime autoload). Needed once per project before any editor_*, game_* or project_* tool.',
  },
  {
    name: 'bridge_status',
    description: 'Report whether the editor and the running game are reachable through the bridge, and whether the installed addon is current.',
  },

  // --- editor ---------------------------------------------------------------
  {
    name: 'editor_status',
    description: 'Live editor state: open scenes, edited scene, selection, whether the game is playing.',
    target: 'editor',
    method: 'editor.status',
  },
  {
    name: 'editor_scene_tree',
    description: 'Node tree of the scene open in the editor. Instanced sub-scenes are collapsed unless expandInstances is set.',
    target: 'editor',
    method: 'editor.scene_tree',
    properties: {
      node: NODE(`Subtree root. ${EDITOR_NODE}`),
      maxDepth: { type: 'number' },
      properties: PROPS_LIST,
      expandInstances: { type: 'boolean' },
    },
  },
  {
    name: 'editor_open_scene',
    description: 'Open a scene in the editor and make it the edited scene.',
    target: 'editor',
    method: 'editor.open_scene',
    properties: { path: { type: 'string', description: 'res:// path of the .tscn' } },
    required: ['path'],
  },
  {
    name: 'editor_create_scene',
    description: 'Create a new scene file with a root node and open it in the editor.',
    target: 'editor',
    method: 'editor.create_scene',
    properties: {
      path: { type: 'string', description: 'res:// path ending in .tscn' },
      rootType: { type: 'string', description: 'Root node class or global class_name (default Node2D)' },
      rootName: { type: 'string' },
      overwrite: { type: 'boolean' },
    },
    required: ['path'],
  },
  {
    name: 'editor_save',
    description: 'Save the edited scene (or every open scene with all: true).',
    target: 'editor',
    method: 'editor.save',
    properties: { all: { type: 'boolean' } },
  },
  {
    name: 'editor_add_node',
    description:
      'Add a node to the edited scene (undoable). Give either type (a class like CharacterBody2D or a global class_name) or scene (a res:// .tscn to instance).',
    target: 'editor',
    method: 'editor.add_node',
    properties: {
      parent: NODE(`Parent. ${EDITOR_NODE}. Default "."`),
      type: { type: 'string' },
      scene: { type: 'string' },
      name: { type: 'string' },
      properties: PROPERTIES,
      index: { type: 'number', description: 'Child index to insert at' },
    },
  },
  {
    name: 'editor_delete_node',
    description: 'Delete a node (and its children) from the edited scene (undoable).',
    target: 'editor',
    method: 'editor.delete_node',
    properties: { node: NODE(EDITOR_NODE) },
    required: ['node'],
  },
  {
    name: 'editor_move_node',
    description: 'Rename, reparent and/or reorder a node in the edited scene (undoable).',
    target: 'editor',
    method: 'editor.move_node',
    properties: {
      node: NODE(EDITOR_NODE),
      newParent: NODE('New parent path'),
      newName: { type: 'string' },
      index: { type: 'number' },
      keepGlobalTransform: { type: 'boolean', description: 'Default true' },
    },
    required: ['node'],
  },
  {
    name: 'editor_get_properties',
    description:
      'Read a node\'s properties in the edited scene. Without names, returns script variables plus properties changed from their defaults (changedOnly: false for all).',
    target: 'editor',
    method: 'editor.get_properties',
    properties: {
      node: NODE(EDITOR_NODE),
      names: { type: 'array', items: { type: 'string' } },
      changedOnly: { type: 'boolean' },
    },
  },
  {
    name: 'editor_set_properties',
    description: 'Set properties on a node in the edited scene, as one undoable action.',
    target: 'editor',
    method: 'editor.set_properties',
    properties: { node: NODE(EDITOR_NODE), properties: PROPERTIES },
    required: ['properties'],
  },
  {
    name: 'editor_select',
    description: 'Select nodes in the editor and show the last one in the Inspector.',
    target: 'editor',
    method: 'editor.select',
    properties: { nodes: { type: 'array', items: { type: 'string' } } },
    required: ['nodes'],
  },
  {
    name: 'editor_attach_script',
    description:
      'Attach a GDScript to a node (undoable). Creates the file with a minimal template if it does not exist (create: false to forbid). Empty script detaches.',
    target: 'editor',
    method: 'editor.attach_script',
    properties: { node: NODE(EDITOR_NODE), script: { type: 'string', description: 'res:// path to a .gd file' }, create: { type: 'boolean' } },
    required: ['script'],
  },
  {
    name: 'editor_signals',
    description:
      'List, connect or disconnect signal connections saved in the edited scene. connect adds a stub method to the target\'s script if missing (default name _on_<node>_<signal>).',
    target: 'editor',
    method: 'editor.signals',
    properties: {
      action: { type: 'string', enum: ['list', 'connect', 'disconnect'] },
      node: NODE(`Signal source. ${EDITOR_NODE}`),
      signal: { type: 'string' },
      target: NODE('Node that receives the signal'),
      method: { type: 'string' },
      binds: { type: 'array', description: 'Extra arguments bound to the call' },
      deferred: { type: 'boolean' },
      oneShot: { type: 'boolean' },
      createMethod: { type: 'boolean', description: 'Add a stub method if missing (default true)' },
      includeBuiltin: { type: 'boolean', description: 'list: include unconnected built-in signals' },
    },
  },
  {
    name: 'editor_play',
    description: 'Run the game from the editor. scene: "main" (default), "current", or a res:// scene path. Then use game_* tools.',
    target: 'editor',
    method: 'editor.play',
    properties: { scene: { type: 'string' } },
  },
  {
    name: 'editor_stop',
    description: 'Stop the game launched from the editor.',
    target: 'editor',
    method: 'editor.stop',
  },
  {
    name: 'editor_screenshot',
    description: 'Screenshot the editor window, or just its 2D or 3D viewport.',
    target: 'editor',
    method: 'editor.screenshot',
    properties: { target: { type: 'string', enum: ['editor', '2d', '3d'] }, maxWidth: MAX_WIDTH },
  },
  {
    name: 'editor_reload_filesystem',
    description:
      'Make the editor pick up files written outside it: rescans res:// and refreshes loaded scripts whose source changed on disk. Call after writing .gd/.tscn files directly.',
    target: 'editor',
    method: 'editor.reload_filesystem',
  },
  {
    name: 'editor_validate_scripts',
    description: 'Compile GDScript files and report errors with line numbers. Defaults to every .gd outside addons/.',
    target: 'editor',
    method: 'editor.validate_scripts',
    properties: { paths: { type: 'array', items: { type: 'string' } }, includeAddons: { type: 'boolean' } },
  },
  {
    name: 'editor_get_log',
    description: 'Editor output and errors since sinceId (use the returned last_id for the next call). Needs Godot 4.5+.',
    target: 'editor',
    method: 'editor.get_log',
    properties: { sinceId: { type: 'number' }, errorsOnly: { type: 'boolean' }, limit: { type: 'number' } },
  },

  // --- project (editor when open, otherwise headless) -----------------------
  {
    name: 'project_settings',
    description:
      'Get or set ProjectSettings (e.g. application/run/main_scene, display/window/size/viewport_width). get: prefix or keys. set: settings object; null removes a setting. Goes through the editor when it is open, otherwise runs Godot headless.',
    target: 'project',
    method: 'project.settings',
    properties: {
      action: { type: 'string', enum: ['get', 'set'] },
      prefix: { type: 'string' },
      keys: { type: 'array', items: { type: 'string' } },
      settings: { type: 'object' },
    },
  },
  {
    name: 'project_input_actions',
    description:
      'Manage the input map. events: [{"type":"key","key":"W"}, {"type":"key","key":"S","ctrl":true}, {"type":"mouse_button","button":"left"}, {"type":"joy_button","button":0}, {"type":"joy_axis","axis":0,"value":-1}]. add appends events, set replaces them.',
    target: 'project',
    method: 'project.input_actions',
    properties: {
      action: { type: 'string', enum: ['list', 'add', 'set', 'remove'] },
      name: { type: 'string' },
      events: { type: 'array', items: { type: 'object' } },
      deadzone: { type: 'number' },
      includeBuiltin: { type: 'boolean', description: 'list: include ui_* actions' },
    },
  },
  {
    name: 'project_autoloads',
    description: 'List, add or remove autoload singletons.',
    target: 'project',
    method: 'project.autoloads',
    properties: {
      action: { type: 'string', enum: ['list', 'add', 'remove'] },
      name: { type: 'string' },
      path: { type: 'string', description: 'res:// path to a script or scene' },
    },
  },

  // --- running game ---------------------------------------------------------
  {
    name: 'game_status',
    description: 'State of the running game: current scene, fps, paused, window size.',
    target: 'game',
    method: 'game.status',
  },
  {
    name: 'game_screenshot',
    description: 'Screenshot the running game. game_input mouse coordinates use this image\'s pixel space.',
    target: 'game',
    method: 'game.screenshot',
    properties: { maxWidth: MAX_WIDTH },
  },
  {
    name: 'game_scene_tree',
    description: 'Live node tree of the running game (default from /root, including autoloads).',
    target: 'game',
    method: 'game.scene_tree',
    properties: { node: NODE(GAME_NODE), maxDepth: { type: 'number' }, properties: PROPS_LIST },
  },
  {
    name: 'game_get_properties',
    description: 'Read properties of a node in the running game (script variables + changed properties by default).',
    target: 'game',
    method: 'game.get_properties',
    properties: { node: NODE(GAME_NODE), names: { type: 'array', items: { type: 'string' } }, changedOnly: { type: 'boolean' } },
    required: ['node'],
  },
  {
    name: 'game_set_properties',
    description: 'Set properties on a node in the running game (not saved to the scene).',
    target: 'game',
    method: 'game.set_properties',
    properties: { node: NODE(GAME_NODE), properties: PROPERTIES },
    required: ['node', 'properties'],
  },
  {
    name: 'game_call_method',
    description: 'Call a method on a node in the running game and return its result.',
    target: 'game',
    method: 'game.call',
    properties: { node: NODE(GAME_NODE), method: { type: 'string' }, args: { type: 'array' } },
    required: ['node', 'method'],
  },
  {
    name: 'game_eval',
    description:
      'Evaluate a Godot Expression in the running game, e.g. "get_node(\'Player\').velocity.length()". Variables: tree, root, scene. Methods resolve against node (default: current scene).',
    target: 'game',
    method: 'game.eval',
    properties: { expression: { type: 'string' }, node: NODE(GAME_NODE) },
    required: ['expression'],
  },
  {
    name: 'game_input',
    description:
      'Send input to the running game, steps run in order. Step types: {"type":"action","action":"jump","hold_ms":100,"mode":"tap|press|release"}, {"type":"key","key":"D","hold_ms":800}, {"type":"text","text":"hello"}, {"type":"click","x":320,"y":200,"button":"left","double":false}, {"type":"mouse_move","x":..,"y":..}, {"type":"drag","from":[x,y],"to":[x,y],"ms":300}, {"type":"scroll","x":..,"y":..,"direction":"up"}, {"type":"wait","ms":500}, {"type":"wait_frames","frames":2}. Mouse coordinates are in the last game_screenshot\'s pixels.',
    target: 'game',
    method: 'game.input',
    properties: { steps: { type: 'array', items: { type: 'object' } } },
    required: ['steps'],
  },
  {
    name: 'game_get_log',
    description: 'Output and errors from the running game since sinceId (use the returned last_id next time). Needs Godot 4.5+.',
    target: 'game',
    method: 'game.get_log',
    properties: { sinceId: { type: 'number' }, errorsOnly: { type: 'boolean' }, limit: { type: 'number' } },
  },
  {
    name: 'game_quit',
    description: 'Ask the running game to quit.',
    target: 'game',
    method: 'game.quit',
  },
];

export const bridgeToolDefinitions = SPECS.map((spec) => ({
  name: spec.name,
  description: spec.description,
  inputSchema: {
    type: 'object',
    properties: {
      projectPath: PROJECT_PATH,
      ...(spec.target && spec.target !== 'project' ? { waitMs: WAIT_MS } : {}),
      ...(spec.properties ?? {}),
    },
    ...(spec.required ? { required: spec.required } : {}),
  },
}));

const SPEC_BY_NAME = new Map(SPECS.map((spec) => [spec.name, spec]));

function snakeCase(key: string): string {
  return key.replace(/[A-Z]/g, (c) => `_${c.toLowerCase()}`);
}

function text(value: unknown, isError = false) {
  return {
    content: [{ type: 'text', text: typeof value === 'string' ? value : JSON.stringify(value, null, 2) }],
    ...(isError ? { isError: true } : {}),
  };
}

function readAddonVersion(addonDir: string): string | null {
  const cfg = join(addonDir, 'plugin.cfg');
  if (!existsSync(cfg)) return null;
  return readFileSync(cfg, 'utf8').match(/^version="([^"]*)"/m)?.[1] ?? null;
}

export class BridgeTools {
  private editor = new BridgeConnection('editor', EDITOR_PORT);
  private game = new BridgeConnection('game', GAME_PORT);

  constructor(private ctx: BridgeContext) {}

  /** Returns the tool result, or null if the tool isn't a bridge tool. */
  async handle(name: string, rawArgs: any): Promise<any | null> {
    const spec = SPEC_BY_NAME.get(name);
    if (!spec) return null;
    const args = { ...(rawArgs ?? {}) };
    try {
      const project = this.resolveProject(args.projectPath);
      delete args.projectPath;
      const waitMs = typeof args.waitMs === 'number' ? args.waitMs : undefined;
      delete args.waitMs;

      if (name === 'bridge_install') return await this.install(project);
      if (name === 'bridge_status') return await this.status(project);

      const params: Record<string, unknown> = {};
      for (const [key, value] of Object.entries(args)) params[snakeCase(key)] = value;

      let result: any;
      if (spec.target === 'project') {
        result = await this.callProject(project, spec.method!, params);
      } else {
        const connection = spec.target === 'editor' ? this.editor : this.game;
        result = await connection.call(project, spec.method!, params, {
          waitMs: waitMs ?? (spec.target === 'game' ? 5000 : 1000),
          timeoutMs: name === 'game_input' ? 30000 + estimateInputMs(params.steps) : 30000,
        });
      }

      if (result && typeof result.png_base64 === 'string') {
        const { png_base64, ...meta } = result;
        return {
          content: [
            { type: 'image', data: png_base64, mimeType: 'image/png' },
            { type: 'text', text: JSON.stringify(meta) },
          ],
        };
      }
      return text(result);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      return text(message, true);
    }
  }

  private resolveProject(projectPath: unknown): string {
    const raw = typeof projectPath === 'string' && projectPath ? projectPath : process.env.GODOT_MCP_PROJECT;
    if (!raw) throw new BridgeError('projectPath is required (or set GODOT_MCP_PROJECT)');
    if (raw.includes('..')) throw new BridgeError('Invalid project path');
    const project = normalizeProjectPath(raw);
    if (!existsSync(join(project, 'project.godot'))) throw new BridgeError(`Not a Godot project: ${project}`);
    return project;
  }

  /** Project commands go through the open editor if possible, so it doesn't overwrite our changes later. */
  private async callProject(project: string, method: string, params: object) {
    try {
      await this.editor.connect(project, 0);
    } catch {
      return this.runHeadless(project, method, params);
    }
    return this.editor.call(project, method, params);
  }

  private async runHeadless(project: string, method: string, params: object) {
    if (!existsSync(join(project, 'addons', 'godot_mcp_bridge', 'plugin.cfg'))) {
      throw new BridgeError('The bridge addon is not installed in this project. Run bridge_install first.');
    }
    const godot = await this.ctx.getGodotPath();
    if (!godot) throw new BridgeError('Could not find the Godot executable (set GODOT_PATH).');
    const { stdout } = await execFileAsync(
      godot,
      ['--headless', '--path', project, '--script', `${ADDON_RES_DIR}/core/headless_runner.gd`, '--', method, JSON.stringify(params)],
      { timeout: 120000, maxBuffer: 16 * 1024 * 1024 }
    );
    const line = stdout.split('\n').find((l) => l.startsWith('MCP_RESULT:'));
    if (!line) throw new BridgeError(`Headless Godot gave no result. Output:\n${stdout.slice(-2000)}`);
    const payload = JSON.parse(line.slice('MCP_RESULT:'.length));
    if (payload.error) throw new BridgeError(payload.error.message);
    return payload.result;
  }

  private async install(project: string) {
    const target = join(project, 'addons', 'godot_mcp_bridge');
    const previous = readAddonVersion(target);
    rmSync(target, { recursive: true, force: true });
    cpSync(this.ctx.addonSource, target, { recursive: true });
    const version = readAddonVersion(target);
    if (!readBridgeToken(project)) {
      mkdirSync(join(project, '.godot'), { recursive: true });
      writeFileSync(join(project, '.godot', 'mcp_bridge_token'), randomBytes(24).toString('hex'));
    }

    let editorOpen = false;
    try {
      await this.editor.connect(project, 0);
      editorOpen = true;
    } catch {
      // No editor for this project with a bridge running.
    }
    if (editorOpen) {
      return text({
        installed: version,
        previous,
        note: 'Files updated. The editor for this project is open: disable and re-enable the plugin (Project Settings > Plugins) or restart the editor to load the new version.',
      });
    }
    const result = await this.runHeadless(project, 'project.enable_bridge', {});
    return text({
      installed: version,
      previous,
      ...result,
      note: 'If this project is already open in an editor without the bridge, enable "Godot MCP Bridge" in Project Settings > Plugins there instead, or restart that editor; otherwise it may overwrite project.godot.',
    });
  }

  private async status(project: string) {
    const probe = async (connection: BridgeConnection) => {
      try {
        return { connected: true, ...(await connection.connect(project, 0)) };
      } catch (error) {
        return { connected: false, reason: error instanceof Error ? error.message : String(error) };
      }
    };
    const installed = readAddonVersion(join(project, 'addons', 'godot_mcp_bridge'));
    const shipped = readAddonVersion(this.ctx.addonSource);
    return text({
      project,
      addon: { installed, shipped, upToDate: installed !== null && installed === shipped },
      editor: await probe(this.editor),
      game: await probe(this.game),
    });
  }
}

function estimateInputMs(steps: unknown): number {
  if (!Array.isArray(steps)) return 0;
  let total = 0;
  for (const step of steps) {
    if (step && typeof step === 'object') {
      total += Number(step.ms ?? 0) + Number(step.hold_ms ?? 80) * (step.double ? 2 : 1);
      if (typeof step.text === 'string') total += step.text.length * 50;
    }
  }
  return total;
}
