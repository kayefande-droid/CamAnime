"""Behavior checks for browser-local release follows and foreground notices."""

import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(shutil.which("node") is None, reason="Node.js is not installed")
def test_release_follow_persists_toggles_and_notifies_once():
    script = r'''
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync('static/js/release-reminders.js', 'utf8');
const store = new Map();
const intervals = [];
const notices = [];
const events = {};
let now = 1_500_000;
const span = { textContent: 'Remind me about releases' };
const button = {
  dataset: { animeId: '42', animeTitle: 'Reminder Series', airingEpoch: '2000', airingEpisode: '8' },
  attrs: { 'aria-pressed': 'false' }, listeners: {},
  parentNode: { appendChild(node) { this.child = node; } },
  querySelector(selector) { return selector === 'span' ? span : null; },
  setAttribute(name, value) { this.attrs[name] = value; },
  addEventListener(name, callback) { this.listeners[name] = callback; }
};
const document = {
  querySelectorAll(selector) { return selector === '.release-follow-toggle' ? [button] : []; },
  getElementById() { return null; },
  createElement(tag) {
    return { tagName: tag, attrs: {}, textContent: '', setAttribute(name, value) { this.attrs[name] = value; } };
  }
};
class NotificationMock {
  static permission = 'granted';
  static requestPermission = async () => 'granted';
  constructor(title, options) { this.title = title; this.options = options; notices.push(this); }
}
const sandbox = {
  document,
  window: { isSecureContext: true, Notification: NotificationMock, addEventListener(name, callback) { events[name] = callback; },
    setInterval(callback, period) { intervals.push({ callback, period }); }, focus() {} },
  localStorage: {
    getItem(key) { return store.has(key) ? store.get(key) : null; },
    setItem(key, value) { store.set(key, value); },
    removeItem(key) { store.delete(key); }
  },
  Date: { now: () => now * 1000 },
  console
};
vm.runInNewContext(source, sandbox);
(async () => {
  if (button.attrs['aria-pressed'] !== 'false') throw new Error('button did not initialize as unfollowed');
  await button.listeners.click();
  const saved = JSON.parse(store.get('camanime_release_follows'));
  if (saved.length !== 1 || saved[0].id !== 42 || saved[0].airingAt !== 2000) {
    throw new Error('follow was not persisted with release metadata');
  }
  if (button.attrs['aria-pressed'] !== 'true' || span.textContent !== 'Release reminder saved') {
    throw new Error('follow button did not expose pressed state');
  }
  if (!button.parentNode.child.textContent.toLowerCase().includes('saved in this browser')) {
    throw new Error('accessible status did not explain local reminder behavior');
  }
  const timer = intervals.find(item => item.period === 30000);
  if (!timer) throw new Error('foreground reminder check was not scheduled');
  if (notices.length !== 0) throw new Error('future release notified early');
  now = 2100;
  timer.callback();
  if (notices.length !== 1 || !notices[0].options.body.includes('Provider availability is not verified')) {
    throw new Error('due reminder did not show an accurately worded notice');
  }
  timer.callback();
  if (notices.length !== 1) throw new Error('same release notified more than once');
  await button.listeners.click();
  if (JSON.parse(store.get('camanime_release_follows')).length !== 0 ||
      button.attrs['aria-pressed'] !== 'false') throw new Error('unfollow did not remove the local entry');
  process.stdout.write('release follow storage, one-time notification, and removal passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    subprocess.run(["node", "-e", script], cwd=ROOT, check=True, text=True)


@pytest.mark.skipif(shutil.which("node") is None, reason="Node.js is not installed")
def test_release_follow_with_denied_permission_is_saved_without_claiming_notification():
    script = r'''
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync('static/js/release-reminders.js', 'utf8');
const store = new Map();
const span = { textContent: '' };
const button = {    dataset: { animeId: '7', animeTitle: 'Blocked Notice', airingEpoch: '9999999999', airingEpisode: '2' },
  attrs: {}, listeners: {}, parentNode: { appendChild(node) { this.child = node; } },
  querySelector: () => span,
  setAttribute(name, value) { this.attrs[name] = value; },
  addEventListener(name, callback) { this.listeners[name] = callback; }
};
const document = {
  querySelectorAll: () => [button], getElementById: () => null,
  createElement: () => ({ setAttribute() {}, textContent: '' })
};
class NotificationMock {
  static permission = 'denied';
  static requestPermission = async () => 'denied';
  constructor() { throw new Error('denied permission must not construct a notification'); }
}
const sandbox = {      document, window: { isSecureContext: true, Notification: NotificationMock, addEventListener() {}, setInterval() {} },
  localStorage: { getItem: key => store.get(key) || null, setItem: (key, value) => store.set(key, value) },
  Date, console
};
vm.runInNewContext(source, sandbox);
(async () => {
  await button.listeners.click();
  const saved = JSON.parse(store.get('camanime_release_follows'));
  if (saved.length !== 1 || button.attrs['aria-pressed'] !== 'true') throw new Error('follow was not saved');
  if (!button.parentNode.child.textContent.toLowerCase().includes('notifications are blocked')) {
    throw new Error('denied state did not disclose that no notification will appear');
  }
  process.stdout.write('permission-denied follow is saved without false notification claims\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    subprocess.run(["node", "-e", script], cwd=ROOT, check=True, text=True)
