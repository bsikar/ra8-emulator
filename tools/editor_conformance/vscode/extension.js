'use strict';
const fs = require('fs');
const vscode = require('vscode');
const state = { messages: [], events: [], session: null };

function activate(context) {
  const config = JSON.parse(fs.readFileSync(process.env.RA8_EDITOR_CONFIG, 'utf8'));
  context.subscriptions.push(vscode.debug.registerDebugAdapterDescriptorFactory('ra8-conformance', {
    createDebugAdapterDescriptor() {
      return new vscode.DebugAdapterServer(config.port, '127.0.0.1');
    }
  }));
  context.subscriptions.push(vscode.debug.registerDebugAdapterTrackerFactory('ra8-conformance', {
    createDebugAdapterTracker(session) {
      state.session = session;
      return {
        onWillReceiveMessage(message) { state.messages.push({ direction: 'client', message }); },
        onDidSendMessage(message) {
          state.messages.push({ direction: 'adapter', message });
          if (message.type === 'event') state.events.push(message);
        },
        onError(error) { state.messages.push({ error: String(error) }); }
      };
    }
  }));
  return state;
}
exports.activate = activate;
