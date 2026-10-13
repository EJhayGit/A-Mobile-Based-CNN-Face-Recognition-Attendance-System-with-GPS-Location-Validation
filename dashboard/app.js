const app = document.querySelector('#app');
let activeMap = null;
let isMobileMenuOpen = false;

const icons = {
  dashboard: '<svg viewBox="0 0 24 24"><path d="M4 13h6V4H4v9Zm0 7h6v-5H4v5Zm10 0h6v-9h-6v9Zm0-16v5h6V4h-6Z"/></svg>',
  drivers: '<svg viewBox="0 0 24 24"><path d="M16 11c1.7 0 3-1.3 3-3s-1.3-3-3-3-3 1.3-3 3 1.3 3 3 3ZM8 11c1.7 0 3-1.3 3-3S9.7 5 8 5 5 6.3 5 8s1.3 3 3 3Zm0 2c-2.3 0-7 1.2-7 3.5V19h14v-2.5C15 14.2 10.3 13 8 13Zm8 0c-.3 0-.7 0-1.1.1 1.2.9 2.1 2 2.1 3.4V19h6v-2.5c0-2.3-4.7-3.5-7-3.5Z"/></svg>',
  delivery: '<svg viewBox="0 0 24 24"><path d="M20 8h-3V4H3a2 2 0 0 0-2 2v11h2a3 3 0 0 0 6 0h6a3 3 0 0 0 6 0h2v-5l-3-4ZM6 18.5A1.5 1.5 0 1 1 6 15a1.5 1.5 0 0 1 0 3.5ZM17 10h2l1.5 2H17v-2Zm1 8.5a1.5 1.5 0 1 1 0-3.5 1.5 1.5 0 0 1 0 3.5Z"/></svg>',
  attendance: '<svg viewBox="0 0 24 24"><path d="M19 3h-1V1h-2v2H8V1H6v2H5a2 2 0 0 0-2 2v16h18V5a2 2 0 0 0-2-2Zm0 16H5V9h14v10Zm-9-2 7-7-1.4-1.4-5.6 5.6-2.6-2.6L6 13l4 4Z"/></svg>',
  audit: '<svg viewBox="0 0 24 24"><path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6Zm0 2.5L17.5 8H14V4.5ZM8 13h8v2H8v-2Zm0 4h8v2H8v-2Zm0-8h4v2H8V9Z"/></svg>',
  theme: '<svg viewBox="0 0 24 24"><path d="M12 18a6 6 0 0 0 0-12v12Zm0 4a10 10 0 1 1 0-20 10 10 0 0 1 0 20Z"/></svg>',
  logout: '<svg viewBox="0 0 24 24"><path d="M10 17v3H3V4h7v3h2V2H1v20h11v-5h-2Zm5-10-1.4 1.4 2.6 2.6H7v2h9.2l-2.6 2.6L15 17l5-5-5-5Z"/></svg>',
};

document.querySelectorAll('[data-icon]').forEach((node) => {
  node.classList.add('icon');
  node.innerHTML = icons[node.dataset.icon];
});

const mobileMenuToggle = document.querySelector('#mobile-menu-toggle');
const mobileMenuClose = document.querySelector('#mobile-menu-close');
const sidebar = document.querySelector('#primary-sidebar');
const sidebarBackdrop = document.querySelector('#sidebar-backdrop');
const mobileNavigationQuery = window.matchMedia('(max-width: 1024px)');

function setMobileMenuOpen(isOpen, restoreFocus = false) {
  isMobileMenuOpen = Boolean(isOpen && mobileNavigationQuery.matches);
  sidebar.classList.toggle('is-open', isMobileMenuOpen);
  sidebar.toggleAttribute('inert', mobileNavigationQuery.matches && !isMobileMenuOpen);
  sidebar.setAttribute('aria-hidden', String(mobileNavigationQuery.matches && !isMobileMenuOpen));
  sidebarBackdrop.hidden = !isMobileMenuOpen;
  mobileMenuToggle.setAttribute('aria-expanded', String(isMobileMenuOpen));
  document.body.classList.toggle('mobile-menu-open', isMobileMenuOpen);
  if (isMobileMenuOpen) mobileMenuClose.focus();
  else if (restoreFocus) mobileMenuToggle.focus();
}

mobileMenuToggle.addEventListener('click', () => setMobileMenuOpen(true));
mobileMenuClose.addEventListener('click', () => setMobileMenuOpen(false, true));
sidebarBackdrop.addEventListener('click', () => setMobileMenuOpen(false, true));
sidebar.querySelectorAll('[data-nav]').forEach((link) => {
  link.addEventListener('click', () => setMobileMenuOpen(false));
});
document.addEventListener('keydown', (event) => {
  if (event.key === 'Escape' && isMobileMenuOpen) setMobileMenuOpen(false, true);
});
mobileNavigationQuery.addEventListener('change', () => setMobileMenuOpen(false));
setMobileMenuOpen(false);

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character]);
}

function userFacingTerminology(value) {
  const source = String(value);
  const trimmed = source.trim();
  const exact = {
    Deliveries: 'Site Assignments',
    Driver: 'Field Personnel',
    Drivers: 'Field Personnel',
    'Active Driver': 'Active Field Personnel',
    'Select Driver': 'Select Field Personnel',
    'All Drivers': 'All Field Personnel',
    'Driver Management': 'Field Personnel Management',
    'Driver ID': 'Field Personnel ID',
    'Delivery Routes': 'Site Assignment History',
    'Delivery History': 'Site Assignment History',
    'Delivery Status': 'Site Assignment Status',
    'Delivery Locations': 'Site Locations',
    'Delivery Location': 'Site Location',
    Location: 'Site Location',
    Locations: 'Site Locations',
    Destinations: 'Site Locations',
    'Create Location': 'Create Site Location',
    'Location name': 'Site Location name',
    'Save Location': 'Save Site Location',
    'Route history': 'Site Assignment History',
    'Route / Stops': 'Site Assignment / Sites',
    'Drop-off stops': 'Site Locations',
    'Assign Route': 'Assign Site Assignment',
    'Build ordered routes, assign Drivers, and track every drop-off.':
      'Build ordered Site Assignments, assign Field Personnel, and track every Site Location.',
  };
  if (Object.prototype.hasOwnProperty.call(exact, trimmed)) {
    return source.replace(trimmed, exact[trimmed]);
  }
  return source
    .replace(/Delivery Locations/g, 'Site Locations')
    .replace(/Delivery Location/g, 'Site Location')
    .replace(/Delivery Routes/g, 'Site Assignment History')
    .replace(/Delivery History/g, 'Site Assignment History')
    .replace(/Delivery Status/g, 'Site Assignment Status')
    .replace(/delivery locations/g, 'Site Locations')
    .replace(/delivery location/g, 'Site Location')
    .replace(/delivery routes/g, 'Site Assignments')
    .replace(/delivery route/g, 'Site Assignment')
    .replace(/Driver Management/g, 'Field Personnel Management')
    .replace(/Driver ID/g, 'Field Personnel ID')
    .replace(/Drop-off stops/g, 'Site Locations')
    .replace(/drop-off stops/g, 'Site Locations')
    .replace(/Drop-off location/g, 'Site Location')
    .replace(/drop-off location/g, 'Site Location')
    .replace(/No active Drivers available/g, 'No active Field Personnel available')
    .replace(/Create an active location first/g, 'Create an active Site Location first')
    .replace(/Create your first delivery location/g, 'Create your first Site Location')
    .replace(/Pin a location and choose its attendance radius/g, 'Pin a Site Location and choose its attendance radius');
}

function applyUserFacingTerminology(root) {
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  while (walker.nextNode()) {
    walker.currentNode.nodeValue = userFacingTerminology(walker.currentNode.nodeValue);
  }
}

function csrf() {
  const row = document.cookie.split('; ').find((item) => item.startsWith('fleet_csrf='));
  return row ? decodeURIComponent(row.split('=')[1]) : '';
}

async function api(path, options = {}) {
  const headers = { ...(options.headers || {}) };
  if (options.body && !(options.body instanceof FormData)) headers['Content-Type'] = 'application/json';
  if (options.method && options.method !== 'GET') headers['X-CSRF-Token'] = csrf();
  let response = await fetch(path, { ...options, headers, cache: 'no-store' });
  if (response.status === 401 && path !== '/api/manager/auth/refresh') {
    const refreshed = await fetch('/api/manager/auth/refresh', {
      method: 'POST', headers: { 'X-CSRF-Token': csrf() },
    });
    if (refreshed.ok) response = await fetch(path, { ...options, headers, cache: 'no-store' });
  }
  if (response.status === 401) {
    window.location.assign('/login');
    throw new Error('Session expired');
  }
  const payload = await response.json();
  if (!response.ok) {
    const detail = Array.isArray(payload.detail)
      ? payload.detail.map((item) => item.msg).join(', ')
      : payload.detail;
    throw new Error(detail || 'Request failed');
  }
  return payload;
}

function showToast(message, kind = 'error') {
  const toast = document.querySelector('#toast');
  toast.className = kind;
  toast.textContent = userFacingTerminology(message);
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { toast.textContent = ''; }, 4000);
}

function confirmDriverDeletion(driver) {
  return new Promise((resolve) => {
    const dialog = document.createElement('dialog');
    dialog.className = 'confirmation-dialog';
    dialog.innerHTML = `<form method="dialog"><p class="eyebrow">Permanent account action</p><h2>Delete Field Personnel?</h2><p>This removes the Field Personnel from active records and revokes active sessions and unused activation codes. Attendance, Site Assignment, and audit history will be preserved.</p><p>Cancel any active Site Assignment first.</p><label>Type <strong>${escapeHtml(driver.full_name)}</strong> to confirm<input name="confirmation" autocomplete="off" required /></label><p class="error" aria-live="polite"></p><div class="actions"><button class="secondary" value="cancel" type="button">Cancel</button><button class="danger" value="confirm" disabled>Delete Field Personnel</button></div></form>`;
    document.body.append(dialog);
    const form = dialog.querySelector('form');
    const input = dialog.querySelector('input');
    const cancel = dialog.querySelector('button[value="cancel"]');
    const confirm = dialog.querySelector('button[value="confirm"]');
    let accepted = false;
    input.addEventListener('input', () => {
      confirm.disabled = input.value !== driver.full_name;
    });
    cancel.addEventListener('click', () => dialog.close());
    form.addEventListener('submit', (event) => {
      event.preventDefault();
      if (input.value !== driver.full_name || confirm.disabled) return;
      accepted = true;
      confirm.disabled = true;
      dialog.close();
    });
    dialog.addEventListener('close', () => {
      dialog.remove();
      resolve(accepted);
    }, { once: true });
    dialog.showModal();
    input.focus();
  });
}

async function deleteDriver(driverId, driver, button) {
  if (button.disabled) return;
  button.disabled = true;
  if (!(await confirmDriverDeletion(driver))) {
    button.disabled = false;
    return;
  }
  try {
    await api(`/api/manager/drivers/${driverId}`, { method: 'DELETE' });
    showToast('Field Personnel deleted.', 'success');
    window.location.assign('/drivers');
  } catch (error) {
    button.disabled = false;
    showToast(error.message);
  }
}

async function copyText(value) {
  if (window.isSecureContext && navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(value);
    return;
  }
  const input = document.createElement('textarea');
  input.value = value;
  input.setAttribute('readonly', '');
  input.style.position = 'fixed';
  input.style.opacity = '0';
  document.body.append(input);
  input.select();
  const copied = document.execCommand('copy');
  input.remove();
  if (!copied) throw new Error('Copy failed. Select and copy the code manually.');
}

function formatDate(value, empty = '—') {
  if (!value) return empty;
  return new Date(value).toLocaleString([], { dateStyle: 'medium', timeStyle: 'short' });
}

function statusLabel(status) {
  if (status === 'completed') return 'Completed';
  return String(status)
    .replaceAll('_', ' ')
    .replace(/\b\w/g, (letter) => letter.toUpperCase())
    .replace(/^Driver /, 'Field Personnel ')
    .replace(/^Delivery /, 'Site Assignment ')
    .replace(/^Location /, 'Site Location ');
}

function badge(status) {
  return `<span class="badge ${escapeHtml(status)}"><i></i>${escapeHtml(statusLabel(status))}</span>`;
}

function pagination(data, pageParameter = 'page') {
  const count = Number(data.count || 0);
  const page = Number(data.page || 1);
  const pageSize = Number(data.page_size || 20);
  const totalPages = Number(data.total_pages || 1);
  const start = count ? ((page - 1) * pageSize) + 1 : 0;
  const end = Math.min(page * pageSize, count);
  const visible = totalPages <= 5
    ? Array.from({ length: totalPages }, (_, index) => index + 1)
    : page <= 3
      ? [1, 2, 3, totalPages]
      : page >= totalPages - 2
        ? [1, totalPages - 2, totalPages - 1, totalPages]
        : [1, page - 1, page, page + 1, totalPages];
  const parts = [];
  let previous = 0;
  visible.forEach((value) => {
    if (previous && value - previous > 1) parts.push('<span class="pagination-gap">…</span>');
    const url = new URL(window.location.href);
    if (value === 1) url.searchParams.delete(pageParameter);
    else url.searchParams.set(pageParameter, String(value));
    parts.push(value === page
      ? `<span class="pagination-current" aria-current="page">${value}</span>`
      : `<a href="${escapeHtml(`${url.pathname}${url.search}`)}">${value}</a>`);
    previous = value;
  });
  const pageLink = (target, label, disabled, ariaLabel) => {
    if (disabled) return `<span class="pagination-disabled" aria-disabled="true" aria-label="${ariaLabel}">${label}</span>`;
    const url = new URL(window.location.href);
    if (target === 1) url.searchParams.delete(pageParameter);
    else url.searchParams.set(pageParameter, String(target));
    return `<a href="${escapeHtml(`${url.pathname}${url.search}`)}" aria-label="${ariaLabel}" title="${ariaLabel}">${label}</a>`;
  };
  return `<nav class="pagination" aria-label="Pagination"><span class="pagination-summary">Showing ${start.toLocaleString()}–${end.toLocaleString()} of ${count.toLocaleString()}</span><span class="pagination-links">${parts.join('')}${pageLink(page + 1, '&gt;', page >= totalPages, 'Next page')}${pageLink(totalPages, '&gt;&gt;', page >= totalPages, 'Last page')}</span></nav>`;
}

function routeTimeline(assignment, compact = false) {
  const stops = assignment.stops || [{ order: 1, state: assignment.status === 'completed' ? 'completed' : 'current', location: assignment.location }];
  return `<div class="route-progress ${compact ? 'compact' : ''}" aria-label="Route progress">${stops.map((stop) => `<div class="route-stop ${escapeHtml(stop.state)}"><span class="route-stop-marker">${stop.state === 'completed' ? '✓' : stop.order}</span><div><strong>${escapeHtml(stop.location.name)}</strong><small>${escapeHtml(stop.location.address || `Stop ${stop.order}`)}</small></div><span class="route-stop-state">${escapeHtml(statusLabel(stop.state))}</span></div>`).join('')}</div>`;
}

function layout(title, description, content, actions = '') {
  if (activeMap) {
    activeMap.remove();
    activeMap = null;
  }
  document.title = `${userFacingTerminology(title)} | AGILA Fleet Manager`;
  app.innerHTML = `<header class="page-header"><div><p class="eyebrow">Fleet operations</p><h1>${escapeHtml(userFacingTerminology(title))}</h1><p class="muted">${escapeHtml(userFacingTerminology(description))}</p></div><div class="header-actions">${actions}</div></header>${content}`;
  applyUserFacingTerminology(app);
  app.focus();
}

function mapMarkerClass(status) {
  return `map-pin ${status}`;
}

function renderMap(elementId, assignments, onSelect) {
  const node = document.querySelector(`#${elementId}`);
  if (!node) return;
  if (!window.L) {
    node.innerHTML = '<div class="map-fallback"><strong>Map unavailable</strong><span>The assignment list remains available.</span></div>';
    return;
  }
  activeMap = L.map(elementId, { zoomControl: true }).setView([14.5995, 120.9842], 11);
  L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
    attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
  }).addTo(activeMap);
  const bounds = [];
  assignments.forEach((assignment) => {
    const { latitude, longitude } = assignment.location;
    L.circle([latitude, longitude], {
      radius: assignment.location.radius_meters,
      color: '#2677e8',
      weight: 2,
      opacity: 0.75,
      fillColor: '#3288ff',
      fillOpacity: 0.1,
      interactive: false,
    }).addTo(activeMap);
    const marker = L.marker([latitude, longitude], {
      icon: L.divIcon({ className: '', html: `<span class="${mapMarkerClass(assignment.status)}"></span>`, iconSize: [24, 30], iconAnchor: [12, 28] }),
    }).addTo(activeMap);
    marker.bindPopup(`<strong>${escapeHtml(assignment.location.name)}</strong><br>${escapeHtml(assignment.driver_name)}<br>${escapeHtml(statusLabel(assignment.status))}`);
    marker.on('click', () => onSelect?.(assignment.id));
    bounds.push([latitude, longitude]);
  });
  if (bounds.length) activeMap.fitBounds(bounds, { padding: [45, 45], maxZoom: 14 });
  setTimeout(() => activeMap?.invalidateSize(), 0);
}

function assignmentCard(assignment, selected = false) {
  return `<button class="assignment-card ${selected ? 'selected' : ''}" data-assignment="${assignment.id}" type="button">
    <span class="assignment-card-top">${badge(assignment.status)}<span>${formatDate(assignment.scheduled_at || assignment.assigned_at)}</span></span>
    <strong>${escapeHtml(assignment.driver_name)}</strong>
    <span class="driver-id">${escapeHtml(assignment.employee_id)}</span>
    <span class="destination">${escapeHtml(assignment.location.name)}</span>
  </button>`;
}

async function overview() {
  const params = new URLSearchParams(window.location.search);
  const facePage = Number(params.get('face_page') || 1);
  const devicePage = Number(params.get('device_page') || 1);
  const [summary, deliveryData, faceRequestData, deviceRequestData] = await Promise.all([
    api('/api/manager/overview'), api('/api/manager/deliveries?page_size=100'),
    api(`/api/manager/face-reregistration-requests?page=${facePage}`),
    api(`/api/manager/device-replacement-requests?page=${devicePage}`),
  ]);
  const active = deliveryData.assignments.filter((item) => ['assigned', 'in_progress'].includes(item.status));
  let selectedId = active[0]?.id;
  const content = `<section class="stat-grid">
    <article><span class="stat-icon drivers">${icons.drivers}</span><div><strong>${summary.active_drivers}</strong><span>Active Field Personnel</span></div></article>
    <article><span class="stat-icon pending">${icons.delivery}</span><div><strong>${summary.pending_deliveries}</strong><span>Pending Site Assignments</span></div></article>
    <article><span class="stat-icon progress">${icons.delivery}</span><div><strong>${summary.in_progress_deliveries}</strong><span>In Progress</span></div></article>
    <article><span class="stat-icon complete">${icons.attendance}</span><div><strong>${summary.completed_today}</strong><span>Completed Today</span></div></article>
  </section>
  <section class="dashboard-grid">
    <article class="panel assignment-panel">
      <div class="panel-heading"><div><p class="eyebrow">Current work</p><h2>Site Assignments</h2></div><span class="count-chip">${active.length}</span></div>
      <label class="search-box"><span>⌕</span><input id="assignment-search" type="search" placeholder="Search Field Personnel or Site Location" /></label>
      <div id="assignment-list" class="assignment-list"></div>
    </article>
    <article class="panel map-panel">
      <div class="panel-heading"><div><p class="eyebrow">Site map</p><h2>Current Site Assignments</h2></div><a href="/deliveries">Manage Site Assignments</a></div>
      <div id="fleet-map" class="fleet-map"></div>
      <div id="selected-assignment" class="selected-assignment"></div>
    </article>
  </section>
  <section class="panel table-wrap">
    <div class="panel-heading"><div><p class="eyebrow">Authorized phone security</p><h2>Device replacement requests</h2></div><span class="count-chip">${deviceRequestData.count}</span></div>
    <table><thead><tr><th>Field Personnel</th><th>Field Personnel ID</th><th>New phone</th><th>Requested</th><th>Action</th></tr></thead><tbody>
      ${deviceRequestData.requests.map((request) => `<tr><td><strong>${escapeHtml(request.driver_name)}</strong></td><td>${escapeHtml(request.employee_id)}</td><td><strong>${escapeHtml(request.device_label || 'Android phone')}</strong><small>Key ${escapeHtml(request.fingerprint_prefix)}</small></td><td>${formatDate(request.requested_at)}</td><td><div class="actions compact"><button data-device-request="${escapeHtml(request.id)}" data-device-driver="${escapeHtml(request.driver_name)}" data-device-decision="approve">Approve</button><button class="danger" data-device-request="${escapeHtml(request.id)}" data-device-driver="${escapeHtml(request.driver_name)}" data-device-decision="reject">Reject</button></div></td></tr>`).join('') || '<tr><td colspan="5"><div class="empty-state"><strong>No pending device replacements.</strong><span>Requests from replacement phones will appear here.</span></div></td></tr>'}
    </tbody></table>${pagination(deviceRequestData, 'device_page')}
  </section>
  <section class="panel table-wrap">
    <div class="panel-heading"><div><p class="eyebrow">Field Personnel security</p><h2>Face re-registration requests</h2></div><span class="count-chip">${faceRequestData.count}</span></div>
    <table><thead><tr><th>Field Personnel</th><th>Field Personnel ID</th><th>Requested</th><th>Status</th><th>Action</th></tr></thead><tbody>
      ${faceRequestData.requests.map((request) => `<tr><td><strong>${escapeHtml(request.driver_name)}</strong></td><td>${escapeHtml(request.employee_id)}</td><td>${formatDate(request.requested_at)}</td><td>${badge(request.status)}</td><td><div class="actions compact"><button data-face-request="${escapeHtml(request.id)}" data-face-driver="${escapeHtml(request.driver_name)}" data-face-decision="approve">Approve</button><button class="danger" data-face-request="${escapeHtml(request.id)}" data-face-driver="${escapeHtml(request.driver_name)}" data-face-decision="reject">Reject</button></div></td></tr>`).join('') || '<tr><td colspan="5"><div class="empty-state"><strong>No pending requests.</strong><span>Field Personnel requests will appear here.</span></div></td></tr>'}
    </tbody></table>${pagination(faceRequestData, 'face_page')}
  </section>`;
  layout('Fleet Dashboard', 'A live view of Site Locations and Field Personnel Site Assignments.', content, '<a class="button" href="/deliveries">+ New Site Assignment</a>');

  const list = document.querySelector('#assignment-list');
  const detail = document.querySelector('#selected-assignment');
  function renderList(items = active) {
    list.innerHTML = items.length
      ? items.map((item) => assignmentCard(item, item.id === selectedId)).join('')
      : '<div class="empty-state"><strong>No Site Assignments yet.</strong><span>Create one from the Site Assignments page.</span></div>';
    list.querySelectorAll('[data-assignment]').forEach((button) => button.addEventListener('click', () => selectAssignment(button.dataset.assignment)));
  }
  function selectAssignment(id) {
    selectedId = id;
    const selected = active.find((item) => item.id === id);
    renderList(active.filter((item) => `${item.driver_name} ${item.employee_id} ${item.location.name}`.toLowerCase().includes(document.querySelector('#assignment-search').value.toLowerCase())));
    detail.innerHTML = selected ? `<div><span class="map-detail-icon">${icons.delivery}</span></div><div><p class="eyebrow">Selected Site Location</p><h3>${escapeHtml(selected.location.name)}</h3><p>${escapeHtml(selected.location.address || 'No address description')}</p></div><div><p class="eyebrow">Assigned Field Personnel</p><strong>${escapeHtml(selected.driver_name)}</strong><span>${escapeHtml(selected.employee_id)}</span></div><div>${badge(selected.status)}</div>` : '';
  }
  document.querySelector('#assignment-search').addEventListener('input', (event) => {
    const term = event.target.value.toLowerCase();
    renderList(active.filter((item) => `${item.driver_name} ${item.employee_id} ${item.location.name}`.toLowerCase().includes(term)));
  });
  renderList();
  selectAssignment(selectedId);
  renderMap('fleet-map', active, selectAssignment);
  document.querySelectorAll('[data-face-request]').forEach((button) => button.addEventListener('click', async () => {
    const decision = button.dataset.faceDecision;
    const label = decision === 'approve' ? 'Approve' : 'Reject';
    if (!window.confirm(`${label} face re-registration for ${button.dataset.faceDriver}?`)) return;
    button.disabled = true;
    try {
      await api(`/api/manager/face-reregistration-requests/${button.dataset.faceRequest}`, {
        method: 'PATCH', body: JSON.stringify({ decision }),
      });
      showToast(`Request ${decision === 'approve' ? 'approved' : 'rejected'}.`, 'success');
      window.location.reload();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
  document.querySelectorAll('[data-device-request]').forEach((button) => button.addEventListener('click', async () => {
    const decision = button.dataset.deviceDecision;
    const label = decision === 'approve' ? 'Approve' : 'Reject';
    const approvalEffect = decision === 'approve'
      ? ' This will sign out the old phone and require supervised face setup on the new phone.'
      : '';
    if (!window.confirm(`${label} device replacement for ${button.dataset.deviceDriver}?${approvalEffect}`)) return;
    button.disabled = true;
    try {
      await api(`/api/manager/device-replacement-requests/${button.dataset.deviceRequest}`, {
        method: 'PATCH', body: JSON.stringify({ decision }),
      });
      showToast(`Device replacement ${decision === 'approve' ? 'approved' : 'rejected'}.`, 'success');
      window.location.reload();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
}

function driverRows(drivers) {
  if (!drivers.length) return '<tr><td colspan="5"><div class="empty-state"><strong>No Field Personnel found.</strong><span>Try another filter or create a Field Personnel account.</span></div></td></tr>';
  return drivers.map((driver) => {
    const action = driver.status === 'disabled' ? 'reactivate' : 'disable';
    const label = action === 'reactivate' ? 'Reactivate' : 'Disable';
    const style = action === 'disable' ? 'danger' : 'secondary';
    return `<tr><td><a class="table-primary" href="/drivers/${driver.id}">${escapeHtml(driver.employee_id)}</a></td><td><a class="table-primary" href="/drivers/${driver.id}">${escapeHtml(driver.full_name)}</a></td><td>${badge(driver.status)}</td><td>${formatDate(driver.created_at)}</td><td><div class="actions compact"><button class="${style}" data-driver-status="${action}" data-driver-id="${escapeHtml(driver.id)}" data-driver-name="${escapeHtml(driver.full_name)}">${label}</button><button class="danger" data-delete-driver-list data-driver-id="${escapeHtml(driver.id)}" data-driver-name="${escapeHtml(driver.full_name)}">Delete</button></div></td></tr>`;
  }).join('');
}

async function driversPage() {
  const params = new URLSearchParams(window.location.search);
  const data = await api(`/api/manager/drivers?${params}`);
  layout('Field Personnel Management', 'Create, search, activate, disable, and reactivate Field Personnel accounts.', `
    <form class="filters panel" id="driver-filter"><input name="search" placeholder="Field Personnel ID or name" value="${escapeHtml(params.get('search') || '')}" /><select name="status"><option value="">All statuses</option>${['pending_activation', 'active', 'disabled'].map((status) => `<option value="${status}" ${params.get('status') === status ? 'selected' : ''}>${statusLabel(status)}</option>`).join('')}</select><select name="sort"><option value="name_asc" ${params.get('sort') === 'name_asc' || !params.get('sort') ? 'selected' : ''}>Name A–Z</option><option value="name_desc" ${params.get('sort') === 'name_desc' ? 'selected' : ''}>Name Z–A</option><option value="id_asc" ${params.get('sort') === 'id_asc' ? 'selected' : ''}>Field Personnel ID</option><option value="created_desc" ${params.get('sort') === 'created_desc' ? 'selected' : ''}>Newest</option><option value="status_asc" ${params.get('sort') === 'status_asc' ? 'selected' : ''}>Status</option></select><button>Filter</button></form>
    <section class="panel table-wrap"><table><thead><tr><th>Field Personnel ID</th><th>Name</th><th>Status</th><th>Created</th><th>Action</th></tr></thead><tbody>${driverRows(data.drivers)}</tbody></table>${pagination(data)}</section>`, '<a class="button" href="/drivers/new">+ Create Field Personnel</a>');
  document.querySelector('#driver-filter').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = new URLSearchParams(new FormData(event.currentTarget));
    [...query].forEach(([key, value]) => { if (!value) query.delete(key); });
    query.delete('page');
    window.location.assign(`/drivers?${query}`);
  });
  document.querySelectorAll('[data-driver-status]').forEach((button) => button.addEventListener('click', async () => {
    const action = button.dataset.driverStatus;
    const driverName = button.dataset.driverName;
    if (action === 'disable' && !window.confirm(`Disable ${driverName}? Their active sessions and unused activation codes will be revoked.`)) return;
    button.disabled = true;
    try {
      await api(`/api/manager/drivers/${button.dataset.driverId}/${action}`, { method: 'PATCH' });
      showToast(`Field Personnel ${action === 'disable' ? 'disabled' : 'reactivated'}.`, 'success');
      window.location.reload();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
  document.querySelectorAll('[data-delete-driver-list]').forEach((button) => button.addEventListener('click', () => {
    deleteDriver(
      button.dataset.driverId,
      { full_name: button.dataset.driverName },
      button,
    );
  }));
}

async function createDriverPage() {
  layout('Create Field Personnel', 'Field Personnel set their permanent password during activation.', `<section class="panel narrow"><form id="create-driver"><div class="form-grid"><label>Field Personnel ID<input name="employee_id" required pattern="[A-Za-z0-9._-]+" /></label><label>Full name<input name="full_name" required /></label></div><label>Phone (optional)<input name="phone" /></label><label>Notes (optional)<textarea name="notes" rows="4"></textarea></label><button>Create Field Personnel</button><p id="form-error" class="error"></p></form><div id="activation-result"></div></section>`);
  document.querySelector('#create-driver').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const values = Object.fromEntries(new FormData(form));
    const submit = form.querySelector('button');
    submit.disabled = true;
    ['phone', 'notes'].forEach((key) => { if (!values[key]) values[key] = null; });
    try {
      const data = await api('/api/manager/drivers', { method: 'POST', body: JSON.stringify(values) });
      form.remove();
      document.querySelector('#activation-result').innerHTML = `<div class="activation"><p class="eyebrow">One-time activation code</p><code id="activation-code">${escapeHtml(data.activation_code)}</code><button id="copy-code" class="secondary">Copy</button><p><strong>Store it safely now.</strong> It cannot be viewed again and expires ${formatDate(data.activation_expires_at)}.</p><a class="button" href="/drivers/${data.driver.id}">Open Field Personnel</a></div>`;
      document.querySelector('#copy-code').addEventListener('click', async () => {
        try {
          await copyText(data.activation_code);
          showToast('Activation code copied.', 'success');
        } catch (error) { showToast(error.message); }
      });
    } catch (error) { submit.disabled = false; document.querySelector('#form-error').textContent = userFacingTerminology(error.message); }
  });
}

async function driverDetail(id) {
  const params = new URLSearchParams(window.location.search);
  const [data, audits] = await Promise.all([api(`/api/manager/drivers/${id}`), api(`/api/manager/drivers/${id}/audit?${params}`)]);
  const driver = data.driver;
  const assignment = driver.current_assignment;
  const assignmentPanel = assignment ? `<div class="assignment-summary"><span class="map-detail-icon">${icons.delivery}</span><div><p class="eyebrow">${escapeHtml(assignment.route_name || 'Current Site Assignment')}</p><h3>${escapeHtml(assignment.location.name)}</h3><p>${assignment.completed_stop_count} of ${assignment.total_stop_count} sites completed</p><span>${formatDate(assignment.scheduled_at || assignment.assigned_at)}</span></div>${badge(assignment.status)}</div>${routeTimeline(assignment)}` : '<div class="empty-state"><strong>No current Site Assignment.</strong><span>Assign this Field Personnel to an active Site Assignment.</span></div>';
  layout(driver.full_name, `Field Personnel ID ${driver.employee_id}`, `<section class="detail-grid"><article class="panel"><div class="panel-heading"><h2>Account</h2>${badge(driver.status)}</div><dl><dt>Activation</dt><dd>${escapeHtml(driver.activation.status)}</dd>${driver.activation.expires_at ? `<dt>Code expires</dt><dd>${formatDate(driver.activation.expires_at)}</dd>` : ''}<dt>Phone</dt><dd>${escapeHtml(driver.phone || '—')}</dd><dt>Notes</dt><dd>${escapeHtml(driver.notes || '—')}</dd></dl><div class="actions">${driver.status === 'disabled' ? '<button data-action="reactivate">Reactivate</button>' : '<button class="danger" data-action="disable">Disable</button>'}${driver.status === 'pending_activation' ? '<button class="secondary" data-action="activation-code">Generate / Reset Activation Code</button>' : ''}<button class="danger" data-delete-driver>Delete Field Personnel</button></div><div id="one-time-code"></div></article><article class="panel"><div class="panel-heading"><h2>Current Site Assignment</h2>${driver.status === 'active' ? `<a class="button secondary" href="/deliveries?driver_id=${driver.id}">Assign Site</a>` : ''}</div>${assignmentPanel}</article><article class="panel full-span"><h2>Site activity history</h2><ol class="audit">${audits.audit.map((item) => `<li><i></i><div><strong>${escapeHtml(statusLabel(item.event_type))}</strong><span>${formatDate(item.created_at)}</span></div></li>`).join('') || '<li>No activity entries.</li>'}</ol>${pagination(audits)}</article></section>`);
  document.querySelectorAll('[data-action]').forEach((button) => button.addEventListener('click', async () => {
    try {
      const action = button.dataset.action;
      if (action === 'activation-code' && !window.confirm('Generate a replacement activation code? Any previous unused code will stop working.')) return;
      button.disabled = true;
      const result = await api(`/api/manager/drivers/${id}/${action}`, { method: action === 'activation-code' ? 'POST' : 'PATCH' });
      if (result.activation_code) {
        document.querySelector('#one-time-code').innerHTML = `<div class="activation"><code id="replacement-activation-code">${escapeHtml(result.activation_code)}</code><button id="copy-replacement-code" class="secondary">Copy</button><p><strong>Copy and send this code now.</strong> It is shown once and cannot be retrieved again.</p></div>`;
        document.querySelector('#copy-replacement-code').addEventListener('click', async () => {
          try {
            await copyText(result.activation_code);
            showToast('Activation code copied.', 'success');
          } catch (error) { showToast(error.message); }
        });
      } else window.location.reload();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
  document.querySelector('[data-delete-driver]').addEventListener('click', async (event) => {
    const button = event.currentTarget;
    await deleteDriver(id, driver, button);
  });
}

function assignmentRows(assignments) {
  if (!assignments.length) return '<tr><td colspan="6"><div class="empty-state"><strong>No Site Assignments yet.</strong><span>Create the first Site Assignment above.</span></div></td></tr>';
  return assignments.map((item) => {
    const startAction = item.status === 'assigned' ? `<select class="status-select" data-status-id="${item.id}"><option value="">Update status…</option><option value="in_progress">Start Route</option></select><button class="secondary" data-edit-stops="${item.id}">Edit Stops</button>` : '';
    const statusAction = ['assigned', 'in_progress'].includes(item.status) ? `<div class="actions compact">${startAction}<button class="danger" data-cancel-route="${item.id}">Cancel Route</button></div>` : '—';
    return `<tr><td><a class="table-primary" href="/drivers/${item.driver_id}">${escapeHtml(item.driver_name)}</a><small>${escapeHtml(item.employee_id)}</small></td><td><strong>${escapeHtml(item.route_name || `Site Assignment ${item.id.slice(0, 8)}`)}</strong><small>${item.completed_stop_count} / ${item.total_stop_count} sites completed</small>${routeTimeline(item, true)}</td><td>${formatDate(item.scheduled_at || item.assigned_at)}</td><td>${badge(item.status)}</td><td>${escapeHtml(item.notes || '—')}</td><td>${statusAction}</td></tr>`;
  }).join('');
}

async function deliveriesPage() {
  const query = new URLSearchParams(window.location.search);
  const deliveryQuery = new URLSearchParams(query);
  deliveryQuery.delete('location_page');
  deliveryQuery.set('page_size', '10');
  const locationPage = Number(query.get('location_page') || 1);
  const [deliveryData, locationData, driverData, activeLocationData] = await Promise.all([
    api(`/api/manager/deliveries?${deliveryQuery}`),
    api(`/api/manager/locations?page=${locationPage}`),
    api('/api/manager/drivers?page_size=100&sort=id_asc'),
    api('/api/manager/locations?active=true&page_size=100'),
  ]);
  const activeDrivers = driverData.drivers.filter((driver) => driver.status === 'active');
  const activeLocations = activeLocationData.locations;
  const selectedDriver = query.get('driver_id') || '';
  const locationOptions = activeLocations.map((location) => `<option value="${location.id}">${escapeHtml(location.name)}</option>`).join('');
  const siteLocationsSection = `<section class="panel location-table"><div class="panel-heading"><div><p class="eyebrow">Saved coordinates</p><h2>Delivery Locations</h2></div><span class="count-chip">${locationData.count}</span></div><div class="table-wrap"><table><thead><tr><th>Location</th><th>Coordinates</th><th>Attendance radius</th><th>Status</th><th>Action</th></tr></thead><tbody>${locationData.locations.map((location) => `<tr><td><strong>${escapeHtml(location.name)}</strong><small>${escapeHtml(location.address || 'No description')}</small></td><td>${location.latitude.toFixed(5)}, ${location.longitude.toFixed(5)}</td><td><strong>${location.radius_meters.toLocaleString()} m</strong></td><td>${badge(location.active ? 'active' : 'disabled')}</td><td><div class="actions compact"><button class="secondary" data-edit-location="${location.id}">Edit</button><button class="secondary" data-toggle-location="${location.id}" data-active="${location.active}">${location.active ? 'Disable' : 'Enable'}</button></div></td></tr>`).join('') || '<tr><td colspan="5"><div class="empty-state"><strong>Create your first delivery location.</strong><span>Pin a location and choose its attendance radius.</span></div></td></tr>'}</tbody></table></div></section>`;
  const siteAssignmentHistorySection = `<section class="panel delivery-table"><div class="panel-heading"><div><p class="eyebrow">Route history</p><h2>Delivery Routes</h2></div></div><form id="delivery-filter" class="filters inline"><select name="driver_id"><option value="">All Drivers</option>${driverData.drivers.map((driver) => `<option value="${driver.id}" ${query.get('driver_id') === driver.id ? 'selected' : ''}>${escapeHtml(driver.employee_id)} — ${escapeHtml(driver.full_name)}</option>`).join('')}</select><select name="status"><option value="">All statuses</option>${['assigned', 'in_progress', 'completed', 'cancelled'].map((status) => `<option value="${status}" ${query.get('status') === status ? 'selected' : ''}>${statusLabel(status)}</option>`).join('')}</select><input name="date" type="date" value="${escapeHtml(query.get('date') || '')}"/><button>Filter</button></form><div class="table-wrap"><table><thead><tr><th>Driver</th><th>Route / Stops</th><th>Scheduled / Assigned</th><th>Status</th><th>Notes</th><th>Action</th></tr></thead><tbody>${assignmentRows(deliveryData.assignments)}</tbody></table></div></section>`;
  layout('Deliveries', 'Build ordered routes, assign Drivers, and track every drop-off.', `<section class="delivery-layout"><article class="panel composer"><div class="panel-heading"><div><p class="eyebrow">Route composer</p><h2 id="assignment-form-title">New Route</h2></div></div><form id="assignment-form"><label>Route name / reference (optional)<input name="route_name" maxlength="160" placeholder="e.g. North AM-01" /></label><label>Active Driver<select name="driver_id" required><option value="">Select Driver</option>${activeDrivers.map((driver) => `<option value="${driver.id}" ${selectedDriver === driver.id ? 'selected' : ''}>${escapeHtml(driver.employee_id)} — ${escapeHtml(driver.full_name)}</option>`).join('')}</select></label><div class="route-composer"><div class="route-composer-heading"><strong>Drop-off stops</strong><button id="add-route-stop" class="secondary compact-button" type="button">+ Add Stop</button></div><div id="route-stop-list"></div></div><label>Scheduled date/time (optional)<input name="scheduled_at" type="datetime-local" /></label><label>Notes (optional)<textarea name="notes" rows="3"></textarea></label><div class="actions"><button id="save-assignment" ${!activeDrivers.length || !activeLocations.length ? 'disabled' : ''}>Assign Route</button><button id="cancel-route-edit" class="secondary" type="button" hidden>Cancel edit</button></div><p class="form-hint">Stops are completed in this order. ${!activeDrivers.length ? 'No active Drivers available. ' : ''}${!activeLocations.length ? 'Create an active location first.' : ''}</p><p id="assignment-error" class="error"></p></form></article><article class="panel location-editor"><div class="panel-heading"><div><p class="eyebrow">Destinations</p><h2 id="location-form-title">Create Location</h2></div></div><form id="location-form"><input name="id" type="hidden" /><label>Location name<input name="name" required /></label><label>Address / description<textarea name="address" rows="2"></textarea></label><div class="form-grid"><label>Latitude<input name="latitude" type="number" min="-90" max="90" step="any" required /></label><label>Longitude<input name="longitude" type="number" min="-180" max="180" step="any" required /></label></div><div class="geofence-fields"><label>Attendance radius (meters)<input name="radius_meters" type="number" min="10" max="5000" step="10" value="100" required /></label><label class="radius-slider-label">Adjust boundary<input id="location-radius-slider" type="range" min="10" max="5000" step="10" value="100" /></label></div><div class="actions"><button>Save Location</button><button id="cancel-location-edit" class="secondary" type="button" hidden>Cancel edit</button></div><p id="location-error" class="error"></p></form></article></section>${siteLocationsSection}${siteAssignmentHistorySection}`);

  document.querySelector('.delivery-table').insertAdjacentHTML('beforeend', pagination(deliveryData));
  document.querySelector('.location-table').insertAdjacentHTML('beforeend', pagination(locationData, 'location_page'));
  const assignmentForm = document.querySelector('#assignment-form');
  const stopList = document.querySelector('#route-stop-list');
  function renderStopEditor(locationIds = ['']) {
    stopList.innerHTML = locationIds.map((locationId, index) => `<div class="route-stop-editor"><span>${index + 1}</span><select required aria-label="Stop ${index + 1}"><option value="">Select destination</option>${locationOptions}</select><div class="actions compact"><button class="secondary compact-button" type="button" data-move-stop="up" ${index === 0 ? 'disabled' : ''}>↑</button><button class="secondary compact-button" type="button" data-move-stop="down" ${index === locationIds.length - 1 ? 'disabled' : ''}>↓</button><button class="danger compact-button" type="button" data-remove-stop ${locationIds.length === 1 ? 'disabled' : ''}>Remove</button></div></div>`).join('');
    [...stopList.querySelectorAll('select')].forEach((select, index) => { select.value = locationIds[index] || ''; });
  }
  function selectedStops() { return [...stopList.querySelectorAll('select')].map((select) => select.value); }
  renderStopEditor();
  document.querySelector('#add-route-stop').addEventListener('click', () => renderStopEditor([...selectedStops(), '']));
  stopList.addEventListener('click', (event) => {
    const button = event.target.closest('button');
    if (!button) return;
    const row = button.closest('.route-stop-editor');
    const rows = [...stopList.querySelectorAll('.route-stop-editor')];
    const index = rows.indexOf(row);
    const values = selectedStops();
    if (button.hasAttribute('data-remove-stop')) values.splice(index, 1);
    if (button.dataset.moveStop === 'up' && index > 0) [values[index - 1], values[index]] = [values[index], values[index - 1]];
    if (button.dataset.moveStop === 'down' && index < values.length - 1) [values[index + 1], values[index]] = [values[index], values[index + 1]];
    renderStopEditor(values);
  });

  assignmentForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const submit = document.querySelector('#save-assignment');
    if (submit.disabled) return;
    submit.disabled = true;
    const values = Object.fromEntries(new FormData(event.currentTarget));
    if (!values.scheduled_at) values.scheduled_at = null;
    else values.scheduled_at = new Date(values.scheduled_at).toISOString();
    if (!values.notes) values.notes = null;
    if (!values.route_name) values.route_name = null;
    values.stops = selectedStops().map((delivery_location_id) => ({ delivery_location_id }));
    try {
      const editingId = event.currentTarget.dataset.assignmentId;
      if (editingId) await api(`/api/manager/deliveries/${editingId}/stops`, { method: 'PUT', body: JSON.stringify({ stops: values.stops }) });
      else await api('/api/manager/deliveries', { method: 'POST', body: JSON.stringify(values) });
      showToast(editingId ? 'Route stops updated.' : 'Route assigned successfully.', 'success');
      await deliveriesPage();
    } catch (error) { submit.disabled = false; document.querySelector('#assignment-error').textContent = userFacingTerminology(error.message); }
  });
  document.querySelectorAll('[data-status-id]').forEach((select) => select.addEventListener('change', async () => {
    if (!select.value) return;
    select.disabled = true;
    try {
      await api(`/api/manager/deliveries/${select.dataset.statusId}`, { method: 'PATCH', body: JSON.stringify({ status: select.value }) });
      showToast(`Assignment marked ${statusLabel(select.value)}.`, 'success');
      await deliveriesPage();
    } catch (error) { select.disabled = false; showToast(error.message); }
  }));
  document.querySelectorAll('[data-edit-stops]').forEach((button) => button.addEventListener('click', () => {
    const assignment = deliveryData.assignments.find((item) => item.id === button.dataset.editStops);
    assignmentForm.dataset.assignmentId = assignment.id;
    assignmentForm.elements.driver_id.value = assignment.driver_id;
    assignmentForm.elements.driver_id.disabled = true;
    assignmentForm.elements.route_name.value = assignment.route_name || '';
    assignmentForm.elements.route_name.disabled = true;
    assignmentForm.elements.scheduled_at.disabled = true;
    assignmentForm.elements.notes.disabled = true;
    renderStopEditor(assignment.stops.map((stop) => stop.location.id));
    document.querySelector('#assignment-form-title').textContent = 'Edit Route Stops';
    document.querySelector('#save-assignment').textContent = 'Save Stop Order';
    document.querySelector('#cancel-route-edit').hidden = false;
    assignmentForm.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }));
  document.querySelector('#cancel-route-edit').addEventListener('click', () => deliveriesPage());
  document.querySelectorAll('[data-cancel-route]').forEach((button) => button.addEventListener('click', async () => {
    if (!window.confirm('Cancel this route? The route will remain in history and will no longer be active.')) return;
    button.disabled = true;
    try {
      await api(`/api/manager/deliveries/${button.dataset.cancelRoute}`, { method: 'PATCH', body: JSON.stringify({ status: 'cancelled' }) });
      showToast('Route cancelled.', 'success');
      await deliveriesPage();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
  document.querySelector('#delivery-filter').addEventListener('submit', (event) => {
    event.preventDefault();
    const params = new URLSearchParams(new FormData(event.currentTarget));
    [...params].forEach(([key, value]) => { if (!value) params.delete(key); });
    params.delete('page');
    params.delete('location_page');
    window.location.assign(`/deliveries?${params}`);
  });
  const locationForm = document.querySelector('#location-form');
  const coordinateGrid = locationForm.querySelector('.form-grid');
  coordinateGrid.insertAdjacentHTML('beforebegin', `<div class="location-picker-shell">
    <div class="location-picker-heading">
      <div><strong>Pin the Site Location</strong><span>Click the map, then drag the pin to fine-tune it.</span></div>
      <button id="clear-location-pin" class="secondary compact-button" type="button">Clear pin</button>
    </div>
    <div id="location-picker-map" class="location-picker-map" aria-label="Site Location picker"></div>
    <div class="geofence-legend"><i></i><span>The blue circle is the attendance boundary and resizes with the radius.</span></div>
    <p id="location-picker-status" class="picker-status" aria-live="polite">No pin selected yet.</p>
  </div>`);

  const defaultCenter = [14.5995, 120.9842];
  const latitudeInput = locationForm.elements.latitude;
  const longitudeInput = locationForm.elements.longitude;
  const radiusInput = locationForm.elements.radius_meters;
  const radiusSlider = document.querySelector('#location-radius-slider');
  const pickerStatus = document.querySelector('#location-picker-status');
  let pickerMap = null;
  let pickerMarker = null;
  let pickerRadius = null;

  function validCoordinates(latitude, longitude) {
    return Number.isFinite(latitude) && Number.isFinite(longitude)
      && latitude >= -90 && latitude <= 90 && longitude >= -180 && longitude <= 180;
  }

  function pickerIcon() {
    return L.divIcon({
      className: 'dropoff-pin-wrap',
      html: '<span class="dropoff-pin"><i></i></span>',
      iconSize: [38, 46],
      iconAnchor: [19, 44],
    });
  }

  function setPickerPosition(latitude, longitude, moveMap = true) {
    const lat = Number(latitude);
    const lng = Number(longitude);
    if (!validCoordinates(lat, lng)) return false;
    latitudeInput.value = lat.toFixed(6);
    longitudeInput.value = lng.toFixed(6);
    pickerStatus.textContent = `Site Location pinned at ${lat.toFixed(6)}, ${lng.toFixed(6)}.`;
    if (!pickerMap) return true;
    if (!pickerMarker) {
      pickerMarker = L.marker([lat, lng], { draggable: true, icon: pickerIcon(), title: 'Drag to adjust Site Location' }).addTo(pickerMap);
      pickerMarker.on('dragend', () => {
        const position = pickerMarker.getLatLng();
        setPickerPosition(position.lat, position.lng, false);
      });
    } else pickerMarker.setLatLng([lat, lng]);
    const radius = Number(radiusInput.value);
    if (!pickerRadius) {
      pickerRadius = L.circle([lat, lng], {
        radius,
        color: '#2677e8',
        weight: 2,
        opacity: 0.9,
        fillColor: '#3288ff',
        fillOpacity: 0.16,
        interactive: false,
      }).addTo(pickerMap);
    } else {
      pickerRadius.setLatLng([lat, lng]);
      pickerRadius.setRadius(radius);
    }
    pickerStatus.textContent = `Site Location pinned at ${lat.toFixed(6)}, ${lng.toFixed(6)} with a ${radius.toLocaleString()} m attendance radius.`;
    if (moveMap) {
      pickerMap.fitBounds(pickerRadius.getBounds(), {
        padding: [38, 38],
        maxZoom: 18,
        animate: false,
      });
    }
    return true;
  }

  function clearPicker() {
    latitudeInput.value = '';
    longitudeInput.value = '';
    pickerStatus.textContent = 'No pin selected yet.';
    if (pickerMarker && pickerMap) pickerMap.removeLayer(pickerMarker);
    if (pickerRadius && pickerMap) pickerMap.removeLayer(pickerRadius);
    pickerMarker = null;
    pickerRadius = null;
    pickerMap?.setView(defaultCenter, 11);
  }

  if (!window.L) {
    document.querySelector('#location-picker-map').innerHTML = '<div class="map-fallback"><strong>Map unavailable</strong><span>You can still enter coordinates below.</span></div>';
  } else {
    pickerMap = L.map('location-picker-map', { zoomControl: true }).setView(defaultCenter, 11);
    activeMap = pickerMap;
    L.tileLayer('https://tile.openstreetmap.org/{z}/{x}/{y}.png', {
      maxZoom: 19,
      attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
    }).addTo(pickerMap);
    pickerMap.on('click', ({ latlng }) => setPickerPosition(latlng.lat, latlng.lng));
    setTimeout(() => pickerMap?.invalidateSize(), 0);
  }

  [latitudeInput, longitudeInput].forEach((input) => input.addEventListener('change', () => {
    const latitude = Number(latitudeInput.value);
    const longitude = Number(longitudeInput.value);
    if (latitudeInput.value && longitudeInput.value && !setPickerPosition(latitude, longitude)) {
      pickerStatus.textContent = 'Enter valid latitude and longitude values.';
    }
  }));
  document.querySelector('#clear-location-pin').addEventListener('click', clearPicker);
  function updateRadius(source) {
    const value = Math.min(5000, Math.max(10, Number(source.value) || 100));
    radiusInput.value = String(value);
    radiusSlider.value = String(value);
    pickerRadius?.setRadius(value);
    if (pickerRadius && pickerMap) {
      pickerMap.fitBounds(pickerRadius.getBounds(), {
        padding: [38, 38],
        maxZoom: 18,
        animate: false,
      });
    }
    if (pickerMarker) {
      const position = pickerMarker.getLatLng();
      pickerStatus.textContent = `Site Location pinned at ${position.lat.toFixed(6)}, ${position.lng.toFixed(6)} with a ${value.toLocaleString()} m attendance radius.`;
    }
  }
  radiusInput.addEventListener('input', () => updateRadius(radiusInput));
  radiusSlider.addEventListener('input', () => updateRadius(radiusSlider));

  function resetLocationForm() {
    locationForm.reset();
    locationForm.elements.id.value = '';
    document.querySelector('#location-form-title').textContent = 'Create Site Location';
    document.querySelector('#cancel-location-edit').hidden = true;
    clearPicker();
  }
  locationForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const submit = locationForm.querySelector('button:not([type="button"])');
    if (submit.disabled) return;
    submit.disabled = true;
    const values = Object.fromEntries(new FormData(locationForm));
    const id = values.id;
    delete values.id;
    values.latitude = Number(values.latitude);
    values.longitude = Number(values.longitude);
    values.radius_meters = Number(values.radius_meters);
    values.address = values.address || null;
    try {
      await api(id ? `/api/manager/locations/${id}` : '/api/manager/locations', { method: id ? 'PATCH' : 'POST', body: JSON.stringify(values) });
      showToast(id ? 'Site Location updated.' : 'Site Location created.', 'success');
      await deliveriesPage();
    } catch (error) { submit.disabled = false; document.querySelector('#location-error').textContent = userFacingTerminology(error.message); }
  });
  document.querySelector('#cancel-location-edit').addEventListener('click', resetLocationForm);
  document.querySelectorAll('[data-edit-location]').forEach((button) => button.addEventListener('click', () => {
    const location = locationData.locations.find((item) => item.id === button.dataset.editLocation);
    locationForm.elements.id.value = location.id;
    locationForm.elements.name.value = location.name;
    locationForm.elements.address.value = location.address || '';
    locationForm.elements.latitude.value = location.latitude;
    locationForm.elements.longitude.value = location.longitude;
    radiusInput.value = location.radius_meters;
    radiusSlider.value = location.radius_meters;
    setPickerPosition(location.latitude, location.longitude);
    document.querySelector('#location-form-title').textContent = 'Edit Site Location';
    document.querySelector('#cancel-location-edit').hidden = false;
    locationForm.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }));
  document.querySelectorAll('[data-toggle-location]').forEach((button) => {
    const location = locationData.locations.find((item) => item.id === button.dataset.toggleLocation);
    button.insertAdjacentHTML('afterend', `<button class="danger" data-delete-location="${location.id}">Delete</button>`);
  });
  document.querySelectorAll('[data-toggle-location]').forEach((button) => button.addEventListener('click', async () => {
    button.disabled = true;
    try {
      await api(`/api/manager/locations/${button.dataset.toggleLocation}`, { method: 'PATCH', body: JSON.stringify({ active: button.dataset.active !== 'true' }) });
      showToast('Site Location status updated.', 'success');
      await deliveriesPage();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
  document.querySelectorAll('[data-delete-location]').forEach((button) => button.addEventListener('click', async () => {
    const location = locationData.locations.find((item) => item.id === button.dataset.deleteLocation);
    const typed = window.prompt(`Delete this Site Location from active records? Attendance and Site Assignment history will be preserved. Cancel any active Site Assignment first.\n\nType ${location.name} to confirm.`);
    if (typed === null) return;
    if (typed !== location.name) { showToast('Site Location name did not match. Nothing was deleted.'); return; }
    button.disabled = true;
    try {
      await api(`/api/manager/locations/${location.id}`, { method: 'DELETE' });
      showToast('Site Location deleted.', 'success');
      await deliveriesPage();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
}

async function attendancePage() {
  const params = new URLSearchParams(window.location.search);
  const [records, drivers] = await Promise.all([api(`/api/manager/attendance?${params}`), api('/api/manager/drivers?page_size=100&sort=id_asc')]);
  const rows = records.attendance.map((item) => `<tr><td>${formatDate(item.captured_at_utc)}</td><td><strong>${escapeHtml(item.driver_name)}</strong><small>${escapeHtml(item.employee_id)}</small></td><td>${escapeHtml(item.site_name || 'Unknown location')}</td><td>${item.face_score.toFixed(4)}</td><td>${item.distance_meters.toFixed(1)} m</td><td>${formatDate(item.server_received_at)}</td></tr>`).join('') || '<tr><td colspan="6"><div class="empty-state"><strong>No attendance found.</strong><span>Synchronized records will appear here.</span></div></td></tr>';
  layout('Attendance', 'Synchronized records accepted from active authenticated Field Personnel.', `<form class="filters panel" id="attendance-filter"><input name="date" type="date" value="${escapeHtml(params.get('date') || '')}"/><select name="driver_id"><option value="">All Field Personnel</option>${drivers.drivers.map((driver) => `<option value="${driver.id}" ${params.get('driver_id') === driver.id ? 'selected' : ''}>${escapeHtml(driver.employee_id)} — ${escapeHtml(driver.full_name)}</option>`).join('')}</select><select name="sort"><option value="captured_desc" ${params.get('sort') === 'captured_desc' || !params.get('sort') ? 'selected' : ''}>Newest captured</option><option value="captured_asc" ${params.get('sort') === 'captured_asc' ? 'selected' : ''}>Oldest captured</option><option value="received_desc" ${params.get('sort') === 'received_desc' ? 'selected' : ''}>Newest received</option><option value="driver_asc" ${params.get('sort') === 'driver_asc' ? 'selected' : ''}>Field Personnel</option><option value="site_asc" ${params.get('sort') === 'site_asc' ? 'selected' : ''}>Site Location</option></select><button>Filter</button></form><section class="panel table-wrap"><table><thead><tr><th>Captured</th><th>Field Personnel</th><th>Site Location</th><th>Face score</th><th>Distance</th><th>Received</th></tr></thead><tbody>${rows}</tbody></table>${pagination(records)}</section>`);
  document.querySelector('#attendance-filter').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = new URLSearchParams(new FormData(event.currentTarget));
    [...query].forEach(([key, value]) => { if (!value) query.delete(key); });
    query.delete('page');
    window.location.assign(`/attendance?${query}`);
  });
}

async function auditPage() {
  const params = new URLSearchParams(window.location.search);
  const data = await api(`/api/manager/audit?${params}`);
  const rows = data.audit.map((item) => `<tr><td>${formatDate(item.created_at)}</td><td>${escapeHtml(statusLabel(item.event_type))}</td><td>${item.driver_name ? `<a class="table-primary" href="/drivers/${item.target_account_id}">${escapeHtml(item.driver_name)}</a><small>${escapeHtml(item.employee_id)}</small>` : '<span class="muted">Fleet Manager</span>'}</td></tr>`).join('') || '<tr><td colspan="3"><div class="empty-state"><strong>No audit entries.</strong></div></td></tr>';
  layout('Site Activity', 'Recent account and Site Assignment workflow activity.', `<section class="panel table-wrap"><table><thead><tr><th>Time</th><th>Event</th><th>Target</th></tr></thead><tbody>${rows}</tbody></table>${pagination(data)}</section>`);
}

function setActiveNav() {
  const path = window.location.pathname;
  document.querySelectorAll('[data-nav]').forEach((link) => {
    const target = link.dataset.nav;
    link.classList.toggle('active', target === '/' ? path === '/' : path.startsWith(target));
  });
}

async function start() {
  try {
    const me = await api('/api/manager/me');
    document.querySelector('#manager-name').textContent = me.manager.login_id;
    setActiveNav();
    const path = window.location.pathname;
    if (path === '/drivers/new') await createDriverPage();
    else if (/^\/drivers\/[\w-]+$/.test(path)) await driverDetail(path.split('/').pop());
    else if (path === '/drivers') await driversPage();
    else if (path === '/deliveries') await deliveriesPage();
    else if (path === '/attendance') await attendancePage();
    else if (path === '/audit') await auditPage();
    else await overview();
  } catch (error) {
    layout('Unable to load workspace', 'The Fleet Manager API did not return a usable response.', `<div class="panel empty-state"><strong>${escapeHtml(error.message)}</strong><span>Refresh the page or verify that FastAPI is running.</span></div>`);
  }
}

document.querySelector('#theme-toggle').addEventListener('click', () => {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  localStorage.setItem('fleet-theme', next);
});
document.querySelector('#logout').addEventListener('click', async () => {
  try { await api('/api/manager/auth/logout', { method: 'POST' }); }
  finally { window.location.assign('/login'); }
});
start();
