"""Behavior checks for browser-side countdowns and the live schedule drawer."""

import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.skipif(shutil.which("node") is None, reason="Node.js is not installed")
def test_release_schedule_js_rollover_and_bounded_refresh():
    script = r'''
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync('static/js/release-schedule.js', 'utf8');
let now = 99999;
const intervals = [];
let fetchCalls = 0;
const state = { textContent: 'Countdown' };
const row = {
  dataset: { airingEpoch: '100000', countdownState: 'upcoming' },
  querySelector: selector => selector === '[data-release-state]' ? state : { textContent: '' }
};
const selectors = {
  '#releaseTickerList .release-ticker[data-airing-epoch], #liveScheduleList .release-ticker[data-airing-epoch]': [row]
};
const list = {
  dataset: { scheduleUrl: '/api/v1/schedule' },
  querySelector: () => row,
  querySelectorAll: () => [row],
  innerHTML: '<div>Scheduled Series - Episode 9 official episode</div>'
};
const document = {
  hidden: false,
  body: { classList: { toggle: () => {} } },
  activeElement: null,
  getElementById: id => id === 'releaseTickerList' ? list : null,
  querySelectorAll: selector => selectors[selector] || [],
  addEventListener: () => {}
};
const sandbox = {
  document,
  window: { location: { origin: 'https://camanime.example' } },
  URL,
  Date: { now: () => now * 1000 },
  setInterval: (callback, period) => intervals.push({ callback, period }),
  fetch: async () => {
    fetchCalls += 1;
    return { ok: true, json: async () => ({
      status: 'success', season: { name: 'FALL', year: 2026 },
      items: [{ id: 10, title: 'Scheduled Series', next_airing_episode: {
        episode: 9, airing_at: 200000
      }, airing_hour: '12:00', playback_available: false,
        official_link_available: true, released_episode: 8,
        official_episode_link: { url: 'https://official.example/8', provider: 'Official' } }]
    }) };
  },
  console
};
vm.runInNewContext(source, sandbox);
(async () => {
  await new Promise(resolve => setTimeout(resolve, 0));
  if (fetchCalls !== 0) throw new Error('initial page duplicated the server-rendered schedule request');
  if (!list.innerHTML.includes('Scheduled Series') || !list.innerHTML.includes('Episode 9')) {
    throw new Error('server-rendered metadata was not retained');
  }
  const ticker = intervals.find(timer => timer.period === 1000);
  const refresh = intervals.find(timer => timer.period === 900000);
  if (!ticker || !refresh) throw new Error('countdown/refresh timers are missing');
  now = 100001;
  ticker.callback();
  if (fetchCalls !== 0) throw new Error('airing rollover caused an immediate request');
  if (row.dataset.countdownState !== 'aired_checking') throw new Error('rollover state was not updated');
  if (!state.textContent.includes('checking provider')) throw new Error('rollover falsely claims playback');
  if (list.innerHTML.includes('/watch/')) throw new Error('metadata fabricated a CamAnime watch link');
  now += 900001;
  sandbox.fetch = async () => {
    fetchCalls += 1;
    return { ok: true, json: async () => ({
      status: 'success', season: { name: 'FALL', year: 2026 },
      items: [{ id: 11, title: 'Unsafe Link', next_airing_episode: {
        episode: 8, airing_at: 100001
      }, airing_hour: '12:00', released_episode: 8, official_link_available: true,
      official_episode_link: { url: 'javascript:alert(1)', provider: 'Bad' } }]
    }) };
  };
  refresh.callback();
  await new Promise(resolve => setTimeout(resolve, 0));
  if (fetchCalls !== 1) throw new Error('schedule did not refresh after 15 minutes');
  if (list.innerHTML.includes('javascript:')) throw new Error('unsafe provider URL rendered');
  process.stdout.write('browser schedule rollover, bounded refresh, and URL safety passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    subprocess.run(["node", "-e", script], cwd=ROOT, check=True, text=True)


@pytest.mark.skipif(shutil.which("node") is None, reason="Node.js is not installed")
def test_live_schedule_drawer_opens_loads_closes_and_restores_focus():
    script = r'''
const fs = require('fs');
const vm = require('vm');
const source = fs.readFileSync('static/js/release-schedule.js', 'utf8');
let now = 1_000_000_000_000;
const intervals = [];
const documentEvents = {};
let fetchCalls = 0;
const classes = initial => {
  const values = new Set(initial || []);
  return { add: name => values.add(name), remove: name => values.delete(name),
    contains: name => values.has(name), toggle: (name, force) => {
      if (force === undefined) force = !values.has(name);
      if (force) values.add(name); else values.delete(name);
      return force;
    } };
};
const makeFocusable = () => ({ focused: false, focus() { this.focused = true; document.activeElement = this; } });
const toggle = makeFocusable();
toggle.listeners = {};
toggle.addEventListener = (name, callback) => { toggle.listeners[name] = callback; };
toggle.attrs = { 'aria-expanded': 'false' };
toggle.dataset = {};
toggle.setAttribute = (name, value) => { toggle.attrs[name] = value; };
toggle.getAttribute = name => toggle.attrs[name];
toggle.classList = classes();
const close = makeFocusable();
close.listeners = {};
close.addEventListener = (name, callback) => { close.listeners[name] = callback; };
const providerLink = makeFocusable();
const drawer = {
  dataset: { scheduleNeedsInitialLoad: 'true' },
  classList: classes(), attrs: {}, listeners: {},
  addEventListener(name, callback) { this.listeners[name] = callback; },
  setAttribute(name, value) { this.attrs[name] = value; },
  querySelector(selector) { return selector === '#liveScheduleClose' ? close : null; },
  querySelectorAll() { return [close, providerLink]; }
};
const backdrop = { hidden: true, listeners: {}, addEventListener(name, callback) { this.listeners[name] = callback; } };
const announcement = { textContent: '' };
const counter = { textContent: '0' };
const tabCounter = { textContent: '0', attrs: {}, setAttribute(name, value) { this.attrs[name] = value; } };
const drawerRow = { dataset: { airingEpoch: '1000000100', countdownState: 'upcoming' },
  querySelector: () => ({ textContent: '' }) };
const mainList = { dataset: { scheduleUrl: '/api/v1/schedule' }, innerHTML: '',
  querySelector() { return null; } };
const scheduleList = { dataset: { scheduleUrl: '/api/v1/schedule' }, innerHTML: '',
  querySelectorAll: () => [drawerRow] };
const body = { classList: classes() };
const document = {};
document.activeElement = toggle;
const elements = {
  releaseTickerList: mainList, liveScheduleDrawer: drawer, liveScheduleList: scheduleList,
  liveScheduleToggle: toggle, liveScheduleClose: close, liveScheduleBackdrop: backdrop,
  liveScheduleCount: counter, liveScheduleTabCount: tabCounter,
  liveScheduleAnnouncement: announcement
};
document.getElementById = id => elements[id] || null;
document.body = body;
document.hidden = false;
document.addEventListener = (name, callback) => { documentEvents[name] = callback; };
document.querySelectorAll = selector => selector.includes('#liveScheduleList') ? [drawerRow] : [];
const sandbox = {
  document, window: { location: { origin: 'https://camanime.example' } }, URL,
  Date: { now: () => now }, setInterval: (callback, period) => intervals.push({ callback, period }),
  fetch: async url => {
    if (url !== '/api/v1/schedule') throw new Error('unexpected schedule URL');
    fetchCalls += 1;
    return { ok: true, json: async () => ({ status: 'success',
      season: { name: 'FALL', year: 2026 },
      items: [{ id: 42, title: 'Drawer Series', next_airing_episode: {
        episode: 5, airing_at: Math.floor(now / 1000) + 3600
      }, airing_hour: '12:00', released_episode: 4,
      official_link_available: false, official_episode_link: null,
      playback_available: false, download_available: false }] }) };
  }, console
};
vm.runInNewContext(source, sandbox);
(async () => {
  if (fetchCalls !== 0) throw new Error('drawer page made an eager duplicate schedule request');
  const click = toggle.listeners.click;
  if (!click) throw new Error('toggle click handler was not registered');
  click();
  await new Promise(resolve => setTimeout(resolve, 0));
  if (fetchCalls !== 1) throw new Error('opening the drawer did not load the current schedule once');
  if (!drawer.classList.contains('is-open') || toggle.attrs['aria-expanded'] !== 'true') {
    throw new Error('drawer did not open with accessible expanded state');
  }
  if (!close.focused || !scheduleList.innerHTML.includes('Drawer Series') ||
      counter.textContent !== '1' || tabCounter.textContent !== '1' ||
      tabCounter.attrs['aria-label'] !== '1 scheduled titles') {
    throw new Error('drawer did not focus its close control or render schedule rows');
  }
  documentEvents.keydown({ key: 'Escape', preventDefault: () => {} });
  if (drawer.classList.contains('is-open') || toggle.attrs['aria-expanded'] !== 'false') {
    throw new Error('Escape did not close the drawer');
  }
  if (document.activeElement !== toggle) throw new Error('closing did not restore focus to the toggle');
  process.stdout.write('live drawer open, load, close, and focus restoration passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    subprocess.run(["node", "-e", script], cwd=ROOT, check=True, text=True)
