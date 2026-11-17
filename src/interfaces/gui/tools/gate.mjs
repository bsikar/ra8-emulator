import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import ts from 'typescript';

const MAX_FILE_LINES = 350;
const MAX_FN_LINES = 80;
const ROOTS = ['src', 'tests', 'e2e', 'client/src', 'tools'];
const CODE_EXTS = new Set(['.ts', '.html', '.css', '.mjs', '.js']);
const TS_JS_EXTS = new Set(['.ts', '.mjs', '.js']);
const BANNED_ANYWHERE = ['mas' + 'ter', 'sla' + 've'];
const BANNED_WORDS = ['MO' + 'SI', 'MI' + 'SO'];
const LEGACY_NEON_HEXES = ['#0A' + '84FF', '#30' + 'D158', '#FF' + 'D60A', '#FF' + '453A', '#BF' + '5AF2'];
const LEGACY_DECORATORS = new Set(['Input', 'Output', 'ViewChild']);

function countLines(text) {
  if (text.length === 0) return 0;
  let breaks = 0;
  for (let i = 0; i < text.length; i++) {
    if (text.charCodeAt(i) === 10) breaks += 1;
  }
  return text.endsWith('\n') ? breaks : breaks + 1;
}

function isAlnum(ch) {
  if (!ch) return false;
  const c = ch.charCodeAt(0);
  return (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
}

function hasWholeWord(line, word) {
  let from = 0;
  while (true) {
    const at = line.indexOf(word, from);
    if (at < 0) return false;
    const end = at + word.length;
    if (!isAlnum(line[at - 1]) && !isAlnum(line[end])) return true;
    from = at + 1;
  }
}

function collectFiles(guiRoot) {
  const out = [];
  function walk(dirRel) {
    const abs = path.join(guiRoot, dirRel);
    if (!fs.existsSync(abs)) return;
    for (const entry of fs.readdirSync(abs, { withFileTypes: true })) {
      if (entry.name.startsWith('.') || entry.name === 'node_modules' || entry.name === 'dist') continue;
      const childRel = path.posix.join(dirRel.replace(/\\/g, '/'), entry.name);
      if (entry.isDirectory()) {
        walk(childRel);
      } else if (CODE_EXTS.has(path.extname(entry.name))) {
        out.push(childRel);
      }
    }
  }
  for (const root of ROOTS) walk(root);
  return out.sort();
}

function checkTermsAndPalette(rel, lines, inSrc, failures) {
  const lowerLegacyHexes = LEGACY_NEON_HEXES.map((h) => h.toLowerCase());
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? '';
    const lower = line.toLowerCase();
    for (const banned of BANNED_ANYWHERE) {
      if (lower.includes(banned)) failures.push(`${rel}:${i + 1}: banned term "${banned}"`);
    }
    for (const word of BANNED_WORDS) {
      if (hasWholeWord(line, word)) failures.push(`${rel}:${i + 1}: banned term "${word}"`);
    }
    if (inSrc) {
      for (const hex of lowerLegacyHexes) {
        if (lower.includes(hex)) failures.push(`${rel}:${i + 1}: forbidden legacy neon color ${hex.toUpperCase()}`);
      }
    }
  }
}

function checkTemplateDirectives(rel, text, lineOffset, failures) {
  const lines = text.split(/\r?\n/);
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i] ?? '';
    if (/\*ngIf\b/.test(line)) failures.push(`${rel}:${lineOffset + i}: legacy *ngIf forbidden (use @if)`);
    if (/\*ngFor\b/.test(line)) failures.push(`${rel}:${lineOffset + i}: legacy *ngFor forbidden (use @for)`);
  }
}

function isSuiteWrapper(node) {
  if (!ts.isCallExpression(node.parent)) return false;
  const callee = node.parent.expression.getText();
  return callee === 'describe' || callee === 'suite' || callee === 'test.describe';
}

function fnLabel(node) {
  if (ts.isFunctionDeclaration(node) && node.name) return node.name.text;
  if (ts.isMethodDeclaration(node) || ts.isGetAccessorDeclaration(node) || ts.isSetAccessorDeclaration(node)) {
    return node.name.getText();
  }
  if (ts.isConstructorDeclaration(node)) return 'constructor';
  if (ts.isVariableDeclaration(node.parent) && ts.isIdentifier(node.parent.name)) return node.parent.name.text;
  return 'anonymous';
}

function checkComponentDecorator(rel, sf, dec, failures) {
  if (!ts.isCallExpression(dec.expression)) return;
  if (dec.expression.expression.getText(sf) !== 'Component') return;
  const arg = dec.expression.arguments[0];
  if (!arg || !ts.isObjectLiteralExpression(arg)) {
    failures.push(`${rel}:${sf.getLineAndCharacterOfPosition(dec.getStart(sf)).line + 1}: @Component missing config`);
    return;
  }
  let hasOnPush = false;
  for (const prop of arg.properties) {
    if (!ts.isPropertyAssignment(prop)) continue;
    const key = prop.name.getText(sf).replace(/['"]/g, '');
    if (key === 'changeDetection' && prop.initializer.getText(sf).includes('ChangeDetectionStrategy.OnPush')) {
      hasOnPush = true;
    }
    if (key === 'template' && (ts.isStringLiteral(prop.initializer) || ts.isNoSubstitutionTemplateLiteral(prop.initializer))) {
      const startLine = sf.getLineAndCharacterOfPosition(prop.initializer.getStart(sf)).line + 1;
      checkTemplateDirectives(rel, prop.initializer.text, startLine, failures);
    }
  }
  if (!hasOnPush) {
    const line = sf.getLineAndCharacterOfPosition(dec.getStart(sf)).line + 1;
    failures.push(`${rel}:${line}: @Component missing ChangeDetectionStrategy.OnPush`);
  }
}

function checkTypeScriptAst(rel, text, inTestDir, failures) {
  const sf = ts.createSourceFile(rel, text, ts.ScriptTarget.Latest, true);
  function visit(node) {
    const line = sf.getLineAndCharacterOfPosition(node.getStart(sf)).line + 1;
    if (node.kind === ts.SyntaxKind.AnyKeyword) {
      failures.push(`${rel}:${line}: forbidden "any" type`);
    } else if (ts.isCatchClause(node) && node.block.statements.length === 0) {
      failures.push(`${rel}:${line}: empty catch {} block forbidden`);
    } else if (ts.isDecorator(node)) {
      if (ts.isCallExpression(node.expression)) {
        const name = node.expression.expression.getText(sf);
        if (LEGACY_DECORATORS.has(name)) failures.push(`${rel}:${line}: legacy @${name}() decorator forbidden`);
      }
      checkComponentDecorator(rel, sf, node, failures);
    } else if (ts.isFunctionLike(node) && node.body) {
      if (!(inTestDir && isSuiteWrapper(node))) {
        const endLine = sf.getLineAndCharacterOfPosition(node.getEnd()).line + 1;
        const span = endLine - line + 1;
        if (span > MAX_FN_LINES) {
          failures.push(`${rel}:${line}: function "${fnLabel(node)}" is ${span} lines (max ${MAX_FN_LINES})`);
        }
      }
    }
    ts.forEachChild(node, visit);
  }
  visit(sf);
}

function runGate() {
  const guiRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
  const files = collectFiles(guiRoot);
  const failures = [];
  for (const rel of files) {
    const text = fs.readFileSync(path.join(guiRoot, rel), 'utf8');
    const lines = text.split(/\r?\n/);
    const total = countLines(text);
    const inSrc = rel.startsWith('src/') || rel.startsWith('client/src/');
    const inTests = rel.startsWith('tests/') || rel.startsWith('e2e/');
    if (total > MAX_FILE_LINES) failures.push(`${rel}: ${total} lines (max ${MAX_FILE_LINES})`);
    if (rel.startsWith('src/') && /\.(spec|test)\.[jt]s$/.test(rel)) {
      failures.push(`${rel}: test files forbidden under src/ (move to tests/ or e2e/)`);
    }
    checkTermsAndPalette(rel, lines, rel.startsWith('src/'), failures);
    if (rel.endsWith('.html')) checkTemplateDirectives(rel, text, 1, failures);
    if (TS_JS_EXTS.has(path.extname(rel))) checkTypeScriptAst(rel, text, inTests || !inSrc, failures);
  }
  if (failures.length > 0) {
    console.error(`gui gate failed (${failures.length} issues):\n` + failures.map((f) => `  - ${f}`).join('\n'));
    process.exit(1);
  }
  console.log(`gui gate: ${files.length} files clean (max ${MAX_FILE_LINES}L/file, ${MAX_FN_LINES}L/fn, OnPush, zero any, inclusive terms)`);
}

runGate();
