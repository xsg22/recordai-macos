(() => {
  'use strict';
  const payload = JSON.parse(document.querySelector('#report-data').textContent);
  const report = payload.report;
  const sources = new Map(report.sources.map(source => [source.id, source]));
  const sourcePanel = document.querySelector('#sources');
  const audio = document.querySelector('#recording-audio');
  const audioStatus = document.querySelector('#audio-status');
  let activeEnd = null;
  let pendingTime = null;
  let highlightTimer = null;
  document.querySelectorAll('.recording-date').forEach(element => {
    const date = new Date(element.dateTime);
    if (!Number.isNaN(date.getTime())) {
      element.textContent = new Intl.DateTimeFormat('zh-CN', {year: 'numeric', month: 'long', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false}).format(date);
    }
  });
  function locate(id, scroll) {
    const ids = id.split(',');
    const source = sources.get(ids[0]);
    if (!source) return;
    sourcePanel.open = true;
    document.querySelectorAll('.source-row.highlight').forEach(row => row.classList.remove('highlight'));
    const row = document.getElementById('source-' + ids[0]);
    const rows = ids.map(i => document.getElementById('source-' + i)).filter(Boolean);
    rows.forEach(r => r.classList.add('highlight'));
    clearTimeout(highlightTimer);
    highlightTimer = setTimeout(() => rows.forEach(r => r.classList.remove('highlight')), 4000);
    if (scroll) row.scrollIntoView({block: 'center', behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'});
    if (audio) {
      audio.pause();
      pendingTime = null;
      activeEnd = null;
      if (source.startSeconds === null) {
        audioStatus.textContent = '该片段没有可信的时间定位，已展开原文。';
        return;
      }
      pendingTime = source.startSeconds;
      activeEnd = Math.max(...ids.map(i => sources.get(i)?.endSeconds ?? source.endSeconds));
      if (audio.readyState >= 1) audio.currentTime = pendingTime;
      audioStatus.textContent = '已定位到引用片段。点击播放器开始回放，段尾会自动暂停。';
    }
  }
  document.addEventListener('click', event => {
    const target = event.target.closest('[data-source], [data-play]');
    if (target) locate(target.dataset.source || target.dataset.play, true);
  });
  if (audio) {
    audio.addEventListener('loadedmetadata', () => {
      if (pendingTime !== null) audio.currentTime = Math.min(pendingTime, audio.duration);
    });
    audio.addEventListener('timeupdate', () => {
      if (activeEnd !== null && audio.currentTime >= activeEnd) {
        audio.pause();
        audio.currentTime = activeEnd;
        activeEnd = null;
        audioStatus.textContent = '引用片段回放结束，已自动暂停。';
      }
    });
    audio.addEventListener('seeking', () => {
      if (activeEnd !== null && (audio.currentTime > activeEnd + .2 || (pendingTime !== null && audio.currentTime < pendingTime - .2))) activeEnd = null;
    });
    audio.addEventListener('error', () => {
      audio.hidden = true;
      audioStatus.textContent = '这份报告未找到随附音频文件，仍可查看完整原文与引用。';
    });
  }
  const storageKey = 'recordai-report-user-state:' + report.recording.id + ':' + report.recording.contentDigest;
  let stored = {};
  let storageAvailable = true;
  const note = document.querySelector('#local-state-note');
  try {
    const value = JSON.parse(localStorage.getItem(storageKey) || '{}');
    if (value && typeof value === 'object' && !Array.isArray(value)) stored = value;
  } catch (_) { storageAvailable = false; }
  document.querySelectorAll('[data-action]').forEach(checkbox => {
    checkbox.checked = stored[checkbox.dataset.action] === true;
    checkbox.addEventListener('change', () => {
      stored[checkbox.dataset.action] = checkbox.checked;
      if (storageAvailable) {
        try { localStorage.setItem(storageKey, JSON.stringify(stored)); }
        catch (_) { storageAvailable = false; }
      }
      note.textContent = storageAvailable ? '勾选已保存在当前浏览器；原始分析 JSON 保持不变。' : '当前环境无法保存勾选，仅在本次打开期间有效；原始分析 JSON 保持不变。';
    });
  });
  if (!storageAvailable && note) note.textContent = '当前环境无法保存勾选，仅在本次打开期间有效。';
  document.querySelector('#print-report').addEventListener('click', () => window.print());
})();
