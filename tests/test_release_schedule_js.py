"""Behavior checks for the browser-side release schedule refresher."""

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
let intervalCallbacks = [];
let fetchCalls = 0;
const state = { textContent: 'Countdown' };
const row = {
  dataset: { airingEpoch: '100000', countdownState: 'upcoming' },
  querySelector: (selector) => selector === '[data-release-state]' ? state : { textContent: '' }
};

const list = {
  dataset: { scheduleUrl: '/api/v1/schedule' },
  querySelectorAll: () => [row],
  innerHTML: '<div>Scheduled Series · Episode 9 <a href="https://official.example/8">Official episode</a></div>'
};
const document = {
  hidden: false,
  getElementById: () => list,
  addEventListener: () => {}
};
const sandbox = {
  document,
  window: { location: { origin: 'https://camanime.example' } },
  URL,
  Date: { now: () => now * 1000 },
  setInterval: (callback, period) => intervalCallbacks.push({ callback, period }),
  fetch: async () => {
    fetchCalls += 1;
    return { ok: true, json: async () => ({
      status: 'success', season: { name: 'FALL', year: 2026 },
      items: [{ id: 10, title: 'Scheduled Series', next_airing_episode: {
        episode: 9, airing_at: 200000, seconds_until_airing: 100000
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
  if (fetchCalls !== 0) throw new Error('page refresh duplicated the server-rendered schedule request');
  if (!list.innerHTML.includes('Scheduled Series') || !list.innerHTML.includes('Episode 9')) {
    throw new Error('server-rendered metadata was not retained');
  }
  const tickTimer = intervalCallbacks.find(timer => timer.period === 1000);
  const refreshTimer = intervalCallbacks.find(timer => timer.period === 900000);
  if (!tickTimer || !refreshTimer) throw new Error('countdown/refresh intervals are missing');
  now = 100001;
  tickTimer.callback();
  await new Promise(resolve => setTimeout(resolve, 0));
  if (fetchCalls !== 0) throw new Error('airing rollover bypassed the 15-minute fetch throttle');
  if (row.dataset.countdownState !== 'aired_checking') throw new Error('airing rollover did not update state');
  if (!state.textContent.includes('checking provider')) throw new Error('rollover falsely claims playback');
  if (list.innerHTML.includes('/watch/')) throw new Error('metadata fabricated a CamAnime watch link');
  if (!list.innerHTML.includes('https://official.example/8')) throw new Error('official provider link was not displayed');
  const unsafeData = JSON.parse(JSON.stringify({
    status: 'success', season: { name: 'FALL', year: 2026 },
    items: [{ id: 11, title: 'Unsafe Link', next_airing_episode: {
      episode: 8, airing_at: 100001, seconds_until_airing: 0
    }, airing_hour: '12:00', released_episode: 8, official_link_available: true,
    official_episode_link: { url: 'javascript:alert(1)', provider: 'Bad' } }]
  }));
  sandbox.fetch = async () => {
    fetchCalls += 1;
    return { ok: true, json: async () => unsafeData };
  };
  now += 900001;
  refreshTimer.callback();
  await new Promise(resolve => setTimeout(resolve, 0));
  if (fetchCalls !== 1) throw new Error('schedule did not refresh after 15 minutes');
  if (list.innerHTML.includes('javascript:')) throw new Error('unsafe provider URL rendered');
  process.stdout.write('browser schedule script behavior passed\n');
})().catch(error => { console.error(error); process.exitCode = 1; });
'''
    subprocess.run(["node", "-e", script], cwd=ROOT, check=True, text=True)
