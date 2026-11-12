/**
 * CamAnime player chrome.
 *
 * One control surface for the native <video> (MP4 and HLS via hls.js).
 * Iframe providers cannot be instrumented cross-origin, so they keep their own
 * controls and this layer hides itself entirely.
 *
 * Progressive enhancement: the <video> ships with `controls`, and those native
 * controls are only removed after the custom bar has bound successfully. If
 * this file fails to load, playback is exactly what it was before.
 */
(function () {
  'use strict';

  var LS = {
    get: function (k) { try { return localStorage.getItem(k); } catch (e) { return null; } },
    set: function (k, v) { try { localStorage.setItem(k, v); } catch (e) {} },
  };

  function fmt(seconds) {
    if (!isFinite(seconds) || seconds < 0) return '0:00';
    var s = Math.floor(seconds % 60);
    var m = Math.floor((seconds / 60) % 60);
    var h = Math.floor(seconds / 3600);
    var mm = h ? String(m).padStart(2, '0') : String(m);
    return (h ? h + ':' : '') + mm + ':' + String(s).padStart(2, '0');
  }

  function init() {
    var box = document.getElementById('caPlayer');
    var video = document.getElementById('nativeVideo');
    if (!box || !video) return;

    var q = function (sel) { return box.querySelector(sel); };
    var playBtn = q('[data-ca="play"]');
    var bigPlay = q('.ca-big-play');
    var muteBtn = q('[data-ca="mute"]');
    var vol = q('#caVol');
    var speed = q('#caSpeed');
    var pipBtn = q('[data-ca="pip"]');
    var fsBtn = q('[data-ca="full"]');
    var ccBtn = q('[data-ca="cc"]');
    var progress = q('.ca-progress');
    var played = q('.ca-played');
    var buffered = q('.ca-buffered');
    var scrub = q('.ca-scrub');
    var curEl = q('.ca-current');
    var durEl = q('.ca-duration');
    var root = document.documentElement;

    if (!playBtn || !progress) return;

    // ── Capability checks: never show a control the browser cannot honor ──
    if (!document.pictureInPictureEnabled || typeof video.requestPictureInPicture !== 'function') {
      if (pipBtn) pipBtn.remove();
    }
    var fsSupported = !!(box.requestFullscreen || box.webkitRequestFullscreen || video.webkitEnterFullscreen);
    if (!fsSupported && fsBtn) fsBtn.remove();

    var hasCaptions = false;
    function refreshCaptions() {
      hasCaptions = video.textTracks && video.textTracks.length > 0;
      if (ccBtn) ccBtn.style.display = hasCaptions ? '' : 'none';
    }
    video.addEventListener('loadedmetadata', refreshCaptions);
    video.textTracks && video.textTracks.addEventListener
      ? video.textTracks.addEventListener('addtrack', refreshCaptions)
      : null;
    refreshCaptions();

    // Custom chrome is live: drop the native controls (once).
    video.removeAttribute('controls');
    box.setAttribute('data-custom', '1');

    // ── Play / pause ──────────────────────────────────────────────────────
    function syncPlayIcon() {
      var paused = video.paused || video.ended;
      box.classList.toggle('paused', paused);
      if (playBtn) {
        playBtn.innerHTML = paused
          ? '<i class="fas fa-play" aria-hidden="true"></i>'
          : '<i class="fas fa-pause" aria-hidden="true"></i>';
        playBtn.setAttribute('aria-label', paused ? 'Play' : 'Pause');
      }
      if (bigPlay) bigPlay.setAttribute('aria-label', paused ? 'Play' : 'Pause');
    }
    function toggle() {
      if (video.paused || video.ended) {
        var p = video.play();
        if (p && p.catch) p.catch(function () { showError('Playback was blocked. Tap play again.'); });
      } else {
        video.pause();
      }
      wake();
    }
    playBtn.addEventListener('click', toggle);
    if (bigPlay) bigPlay.addEventListener('click', toggle);
    video.addEventListener('play', syncPlayIcon);
    video.addEventListener('pause', syncPlayIcon);
    video.addEventListener('ended', syncPlayIcon);
    video.addEventListener('click', function (e) {
      // A tap on the picture is "reveal controls", not "pause": that is the
      // behaviour people expect from a phone video app.
      if (isTouch()) { e.preventDefault(); toggleIdle(); } else { toggle(); }
    });
    video.addEventListener('dblclick', function () { if (fsBtn) toggleFullscreen(); });

    // ── Progress ──────────────────────────────────────────────────────────
    function pct(ratio) { return (Math.max(0, Math.min(1, ratio)) * 100) + '%'; }
    function paint() {
      var d = video.duration;
      if (d && isFinite(d)) {
        var r = video.currentTime / d;
        played.style.width = pct(r);
        if (scrub) scrub.style.left = pct(r);
        if (durEl) durEl.textContent = fmt(d);
        progress.setAttribute('aria-valuenow', String(Math.round(r * 100)));
      }
      if (curEl) curEl.textContent = fmt(video.currentTime);
      var b = 0;
      try {
        if (video.buffered && video.buffered.length) {
          for (var i = 0; i < video.buffered.length; i++) {
            if (video.buffered.start(i) <= video.currentTime && video.buffered.end(i) >= video.currentTime) {
              b = video.buffered.end(i);
              break;
            }
          }
          if (!b) b = video.buffered.end(video.buffered.length - 1);
        }
      } catch (e) {}
      if (buffered && d && isFinite(d)) buffered.style.width = pct(b / d);
    }
    video.addEventListener('timeupdate', paint);
    video.addEventListener('progress', paint);
    video.addEventListener('durationchange', paint);
    video.addEventListener('loadedmetadata', paint);

    function seekTo(clientX) {
      var rect = progress.getBoundingClientRect();
      var d = video.duration;
      if (!rect.width || !d || !isFinite(d)) return;
      var r = (clientX - rect.left) / rect.width;
      video.currentTime = Math.max(0, Math.min(d, r * d));
      paint();
    }
    var dragging = false;
    progress.addEventListener('pointerdown', function (e) {
      dragging = true;
      progress.setPointerCapture && progress.setPointerCapture(e.pointerId);
      seekTo(e.clientX);
    });
    progress.addEventListener('pointermove', function (e) { if (dragging) seekTo(e.clientX); });
    function endDrag() { dragging = false; }
    progress.addEventListener('pointerup', endDrag);
    progress.addEventListener('pointercancel', endDrag);
    progress.addEventListener('keydown', function (e) {
      var step = e.shiftKey ? 30 : 5;
      if (e.key === 'ArrowRight') { video.currentTime = Math.min(video.duration || 0, video.currentTime + step); e.preventDefault(); }
      if (e.key === 'ArrowLeft') { video.currentTime = Math.max(0, video.currentTime - step); e.preventDefault(); }
      if (e.key === 'Home') { video.currentTime = 0; e.preventDefault(); }
      if (e.key === 'End') { video.currentTime = (video.duration || 0) - 1; e.preventDefault(); }
      paint();
    });

    // ── Volume ────────────────────────────────────────────────────────────
    var savedVol = LS.get('camanime-volume');
    if (savedVol !== null) {
      var v = parseFloat(savedVol);
      if (isFinite(v)) video.volume = Math.max(0, Math.min(1, v));
    }
    function syncVolume() {
      var muted = video.muted || video.volume === 0;
      if (vol) vol.value = String(muted ? 0 : video.volume);
      if (muteBtn) {
        muteBtn.innerHTML = muted
          ? '<i class="fas fa-volume-mute" aria-hidden="true"></i>'
          : (video.volume < 0.5
            ? '<i class="fas fa-volume-down" aria-hidden="true"></i>'
            : '<i class="fas fa-volume-up" aria-hidden="true"></i>');
        muteBtn.setAttribute('aria-label', muted ? 'Unmute' : 'Mute');
      }
    }
    if (muteBtn) muteBtn.addEventListener('click', function () {
      video.muted = !video.muted;
      if (!video.muted && video.volume === 0) video.volume = 0.6;
      syncVolume();
    });
    if (vol) vol.addEventListener('input', function () {
      video.volume = parseFloat(vol.value);
      video.muted = video.volume === 0;
      LS.set('camanime-volume', String(video.volume));
      syncVolume();
    });
    video.addEventListener('volumechange', syncVolume);
    syncVolume();

    // ── Speed ─────────────────────────────────────────────────────────────
    var savedRate = parseFloat(LS.get('camanime-rate') || '1');
    if (speed) {
      speed.value = String(['0.5', '0.75', '1', '1.25', '1.5', '2'].indexOf(String(savedRate)) === -1 ? 1 : savedRate);
      video.playbackRate = parseFloat(speed.value);
      speed.addEventListener('change', function () {
        video.playbackRate = parseFloat(speed.value);
        LS.set('camanime-rate', speed.value);
      });
    }

    // ── Picture in picture ────────────────────────────────────────────────
    if (pipBtn) pipBtn.addEventListener('click', function () {
      if (document.pictureInPictureElement) document.exitPictureInPicture().catch(function () {});
      else video.requestPictureInPicture().catch(function () { showError('Picture-in-picture is not available for this source.'); });
    });

    // ── Fullscreen (element API with iOS video fallback) ───────────────────
    function isFullscreen() {
      return document.fullscreenElement === box || document.webkitFullscreenElement === box;
    }
    function toggleFullscreen() {
      if (isFullscreen()) {
        (document.exitFullscreen || document.webkitExitFullscreen || function () {}).call(document);
      } else if (box.requestFullscreen) {
        box.requestFullscreen().catch(function () {});
      } else if (box.webkitRequestFullscreen) {
        box.webkitRequestFullscreen();
      } else if (video.webkitEnterFullscreen) {
        video.webkitEnterFullscreen();   // iPhone: native video fullscreen
      }
    }
    if (fsBtn) fsBtn.addEventListener('click', toggleFullscreen);
    document.addEventListener('fullscreenchange', function () {
      var on = isFullscreen();
      if (fsBtn) {
        fsBtn.innerHTML = on
          ? '<i class="fas fa-compress" aria-hidden="true"></i>'
          : '<i class="fas fa-expand" aria-hidden="true"></i>';
        fsBtn.setAttribute('aria-label', on ? 'Exit fullscreen' : 'Fullscreen');
      }
      if (isTouch()) { root.style.setProperty('--ca-fs', on ? '1' : '0'); }
    });

    // ── Captions ──────────────────────────────────────────────────────────
    if (ccBtn) ccBtn.addEventListener('click', function () {
      var tracks = video.textTracks || [];
      var anyOn = false;
      for (var i = 0; i < tracks.length; i++) if (tracks[i].mode === 'showing') anyOn = true;
      for (var j = 0; j < tracks.length; j++) tracks[j].mode = anyOn ? 'disabled' : 'showing';
      ccBtn.setAttribute('aria-pressed', anyOn ? 'false' : 'true');
    });

    // ── Loading / error states ────────────────────────────────────────────
    var errEl = q('.ca-error');
    var errText = q('.ca-error-text');
    function showError(msg) {
      box.classList.add('failed');
      if (errText) errText.textContent = msg || 'Playback failed.';
      wake();
    }
    function clearError() { box.classList.remove('failed'); }
    var retry = q('[data-ca="retry"]');
    if (retry) retry.addEventListener('click', function () {
      clearError();
      box.classList.add('loading');
      var t = video.currentTime;
      video.load();
      video.currentTime = t || 0;
      var p = video.play();
      if (p && p.catch) p.catch(function () {});
    });

    video.addEventListener('waiting', function () { box.classList.add('loading'); });
    video.addEventListener('stalled', function () { box.classList.add('loading'); });
    video.addEventListener('seeking', function () { box.classList.add('loading'); });
    video.addEventListener('playing', function () {
      box.classList.remove('loading');
      // Artwork is a pre-play backdrop only; it must never sit over frames.
      box.classList.add('is-playing');
      clearError();
      wake();
    });
    video.addEventListener('loadstart', function () { box.classList.remove('is-playing'); });
    video.addEventListener('emptied', function () { box.classList.remove('is-playing'); });
    video.addEventListener('canplay', function () { box.classList.remove('loading'); });
    video.addEventListener('seeked', function () { box.classList.remove('loading'); });
    video.addEventListener('error', function () {
      box.classList.remove('loading');
      box.classList.remove('is-playing');
      var code = video.error && video.error.code;
      showError(code === 4
        ? 'This source is no longer available. Try another server.'
        : 'The stream stopped. Check your connection or switch servers.');
    });

    // ── Idle hiding ───────────────────────────────────────────────────────
    var idleTimer = null;
    function wake() {
      box.classList.remove('idle');
      clearTimeout(idleTimer);
      if (!video.paused && !video.ended) {
        idleTimer = setTimeout(function () { box.classList.add('idle'); }, 2600);
      }
    }
    function toggleIdle() {
      if (box.classList.contains('idle')) wake();
      else { box.classList.add('idle'); clearTimeout(idleTimer); }
    }
    ['pointermove', 'pointerdown', 'focusin'].forEach(function (evt) {
      box.addEventListener(evt, wake, { passive: true });
    });
    box.addEventListener('pointerleave', function () {
      if (!video.paused) idleTimer = setTimeout(function () { box.classList.add('idle'); }, 1200);
    });
    video.addEventListener('pause', function () { box.classList.remove('idle'); });

    // ── Keyboard (only while the player has focus) ────────────────────────
    box.setAttribute('tabindex', '-1');
    box.addEventListener('keydown', function (e) {
      var tag = (e.target.tagName || '').toLowerCase();
      if (tag === 'select' || tag === 'input' || tag === 'button') return;
      switch (e.key.toLowerCase()) {
        case ' ': case 'k': toggle(); e.preventDefault(); break;
        case 'arrowright': video.currentTime = Math.min(video.duration || 0, video.currentTime + 5); e.preventDefault(); break;
        case 'arrowleft': video.currentTime = Math.max(0, video.currentTime - 5); e.preventDefault(); break;
        case 'arrowup': video.volume = Math.min(1, video.volume + 0.1); syncVolume(); e.preventDefault(); break;
        case 'arrowdown': video.volume = Math.max(0, video.volume - 0.1); syncVolume(); e.preventDefault(); break;
        case 'm': video.muted = !video.muted; syncVolume(); e.preventDefault(); break;
        case 'f': if (fsBtn) toggleFullscreen(); e.preventDefault(); break;
        case 'c': if (ccBtn) ccBtn.click(); e.preventDefault(); break;
        default: break;
      }
    });

    function isTouch() {
      return window.matchMedia && window.matchMedia('(hover: none)').matches;
    }

    syncPlayIcon();
    paint();
    wake();

    // The page's server switcher controls which surface is visible.
    window.caPlayerSetMode = function (mode) {
      var native = mode === 'mp4' || mode === 'hls';
      box.style.display = native ? '' : 'none';
      if (!native) { try { video.pause(); } catch (e) {} }
      else { syncPlayIcon(); paint(); }
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
