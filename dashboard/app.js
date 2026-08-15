const app = document.querySelector('#app');
let activeMap = null;

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

function escapeHtml(value) {
  return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;',
  })[character]);
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
  toast.textContent = message;
  clearTimeout(showToast.timer);
  showToast.timer = setTimeout(() => { toast.textContent = ''; }, 4000);
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
  if (status === 'completed') return 'Delivered';
  return String(status).replaceAll('_', ' ').replace(/\b\w/g, (letter) => letter.toUpperCase());
}

function badge(status) {
  return `<span class="badge ${escapeHtml(status)}"><i></i>${escapeHtml(statusLabel(status))}</span>`;
}

function layout(title, description, content, actions = '') {
  if (activeMap) {
    activeMap.remove();
    activeMap = null;
  }
  document.title = `${title} | AGILA Fleet Manager`;
  app.innerHTML = `<header class="page-header"><div><p class="eyebrow">Fleet operations</p><h1>${escapeHtml(title)}</h1><p class="muted">${escapeHtml(description)}</p></div><div class="header-actions">${actions}</div></header>${content}`;
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
  const [summary, deliveryData] = await Promise.all([
    api('/api/manager/overview'), api('/api/manager/deliveries'),
  ]);
  const active = deliveryData.assignments.filter((item) => ['assigned', 'in_progress'].includes(item.status));
  let selectedId = active[0]?.id;
  const content = `<section class="stat-grid">
    <article><span class="stat-icon drivers">${icons.drivers}</span><div><strong>${summary.active_drivers}</strong><span>Active Drivers</span></div></article>
    <article><span class="stat-icon pending">${icons.delivery}</span><div><strong>${summary.pending_deliveries}</strong><span>Pending Deliveries</span></div></article>
    <article><span class="stat-icon progress">${icons.delivery}</span><div><strong>${summary.in_progress_deliveries}</strong><span>In Progress</span></div></article>
    <article><span class="stat-icon complete">${icons.attendance}</span><div><strong>${summary.completed_today}</strong><span>Delivered Today</span></div></article>
  </section>
  <section class="dashboard-grid">
    <article class="panel assignment-panel">
      <div class="panel-heading"><div><p class="eyebrow">Current work</p><h2>Delivery assignments</h2></div><span class="count-chip">${active.length}</span></div>
      <label class="search-box"><span>⌕</span><input id="assignment-search" type="search" placeholder="Search Driver or destination" /></label>
      <div id="assignment-list" class="assignment-list"></div>
    </article>
    <article class="panel map-panel">
      <div class="panel-heading"><div><p class="eyebrow">Destination map</p><h2>Current assignments</h2></div><a href="/deliveries">Manage deliveries</a></div>
      <div id="fleet-map" class="fleet-map"></div>
      <div id="selected-assignment" class="selected-assignment"></div>
    </article>
  </section>`;
  layout('Fleet Dashboard', 'A live view of database-backed delivery destinations and Driver assignments.', content, '<a class="button" href="/deliveries">+ New assignment</a>');

  const list = document.querySelector('#assignment-list');
  const detail = document.querySelector('#selected-assignment');
  function renderList(items = active) {
    list.innerHTML = items.length
      ? items.map((item) => assignmentCard(item, item.id === selectedId)).join('')
      : '<div class="empty-state"><strong>No delivery assignments yet.</strong><span>Create an assignment from the Deliveries page.</span></div>';
    list.querySelectorAll('[data-assignment]').forEach((button) => button.addEventListener('click', () => selectAssignment(button.dataset.assignment)));
  }
  function selectAssignment(id) {
    selectedId = id;
    const selected = active.find((item) => item.id === id);
    renderList(active.filter((item) => `${item.driver_name} ${item.employee_id} ${item.location.name}`.toLowerCase().includes(document.querySelector('#assignment-search').value.toLowerCase())));
    detail.innerHTML = selected ? `<div><span class="map-detail-icon">${icons.delivery}</span></div><div><p class="eyebrow">Selected destination</p><h3>${escapeHtml(selected.location.name)}</h3><p>${escapeHtml(selected.location.address || 'No address description')}</p></div><div><p class="eyebrow">Assigned Driver</p><strong>${escapeHtml(selected.driver_name)}</strong><span>${escapeHtml(selected.employee_id)}</span></div><div>${badge(selected.status)}</div>` : '';
  }
  document.querySelector('#assignment-search').addEventListener('input', (event) => {
    const term = event.target.value.toLowerCase();
    renderList(active.filter((item) => `${item.driver_name} ${item.employee_id} ${item.location.name}`.toLowerCase().includes(term)));
  });
  renderList();
  selectAssignment(selectedId);
  renderMap('fleet-map', active, selectAssignment);
}

function driverRows(drivers) {
  if (!drivers.length) return '<tr><td colspan="5"><div class="empty-state"><strong>No Drivers found.</strong><span>Try another filter or create a Driver.</span></div></td></tr>';
  return drivers.map((driver) => {
    const action = driver.status === 'disabled' ? 'reactivate' : 'disable';
    const label = action === 'reactivate' ? 'Reactivate' : 'Disable';
    const style = action === 'disable' ? 'danger' : 'secondary';
    return `<tr><td><a class="table-primary" href="/drivers/${driver.id}">${escapeHtml(driver.employee_id)}</a></td><td>${escapeHtml(driver.full_name)}</td><td>${badge(driver.status)}</td><td>${formatDate(driver.created_at)}</td><td><button class="${style}" data-driver-status="${action}" data-driver-id="${escapeHtml(driver.id)}" data-driver-name="${escapeHtml(driver.full_name)}">${label}</button></td></tr>`;
  }).join('');
}

async function driversPage() {
  const params = new URLSearchParams(window.location.search);
  const data = await api(`/api/manager/drivers?${params}`);
  layout('Drivers', 'Create, search, activate, disable, and reactivate Driver accounts.', `
    <form class="filters panel" id="driver-filter"><input name="search" placeholder="Employee ID or name" value="${escapeHtml(params.get('search') || '')}" /><select name="status"><option value="">All statuses</option>${['pending_activation', 'active', 'disabled'].map((status) => `<option value="${status}" ${params.get('status') === status ? 'selected' : ''}>${statusLabel(status)}</option>`).join('')}</select><button>Filter</button></form>
    <section class="panel table-wrap"><table><thead><tr><th>Employee ID</th><th>Name</th><th>Status</th><th>Created</th><th>Action</th></tr></thead><tbody>${driverRows(data.drivers)}</tbody></table></section>`, '<a class="button" href="/drivers/new">+ Create Driver</a>');
  document.querySelector('#driver-filter').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = new URLSearchParams(new FormData(event.currentTarget));
    [...query].forEach(([key, value]) => { if (!value) query.delete(key); });
    window.location.assign(`/drivers?${query}`);
  });
  document.querySelectorAll('[data-driver-status]').forEach((button) => button.addEventListener('click', async () => {
    const action = button.dataset.driverStatus;
    const driverName = button.dataset.driverName;
    if (action === 'disable' && !window.confirm(`Disable ${driverName}? Their active sessions and unused activation codes will be revoked.`)) return;
    button.disabled = true;
    try {
      await api(`/api/manager/drivers/${button.dataset.driverId}/${action}`, { method: 'PATCH' });
      showToast(`Driver ${action === 'disable' ? 'disabled' : 'reactivated'}.`, 'success');
      window.location.reload();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
}

async function createDriverPage() {
  layout('Create Driver', 'The Driver sets their permanent password during activation.', `<section class="panel narrow"><form id="create-driver"><div class="form-grid"><label>Employee ID<input name="employee_id" required pattern="[A-Za-z0-9._-]+" /></label><label>Full name<input name="full_name" required /></label></div><label>Phone (optional)<input name="phone" /></label><label>Notes (optional)<textarea name="notes" rows="4"></textarea></label><button>Create Driver</button><p id="form-error" class="error"></p></form><div id="activation-result"></div></section>`);
  document.querySelector('#create-driver').addEventListener('submit', async (event) => {
    event.preventDefault();
    const form = event.currentTarget;
    const values = Object.fromEntries(new FormData(form));
    ['phone', 'notes'].forEach((key) => { if (!values[key]) values[key] = null; });
    try {
      const data = await api('/api/manager/drivers', { method: 'POST', body: JSON.stringify(values) });
      form.remove();
      document.querySelector('#activation-result').innerHTML = `<div class="activation"><p class="eyebrow">One-time activation code</p><code id="activation-code">${escapeHtml(data.activation_code)}</code><button id="copy-code" class="secondary">Copy</button><p><strong>Store it safely now.</strong> It cannot be viewed again and expires ${formatDate(data.activation_expires_at)}.</p><a class="button" href="/drivers/${data.driver.id}">Open Driver</a></div>`;
      document.querySelector('#copy-code').addEventListener('click', async () => {
        try {
          await copyText(data.activation_code);
          showToast('Activation code copied.', 'success');
        } catch (error) { showToast(error.message); }
      });
    } catch (error) { document.querySelector('#form-error').textContent = error.message; }
  });
}

async function driverDetail(id) {
  const [data, audits] = await Promise.all([api(`/api/manager/drivers/${id}`), api(`/api/manager/drivers/${id}/audit`)]);
  const driver = data.driver;
  const assignment = driver.current_assignment;
  const assignmentPanel = assignment ? `<div class="assignment-summary"><span class="map-detail-icon">${icons.delivery}</span><div><p class="eyebrow">Current destination</p><h3>${escapeHtml(assignment.location.name)}</h3><p>${escapeHtml(assignment.location.address || 'No address description')}</p><span>${formatDate(assignment.scheduled_at || assignment.assigned_at)}</span></div>${badge(assignment.status)}</div>` : '<div class="empty-state"><strong>No current assignment.</strong><span>Assign this Driver to an active delivery location.</span></div>';
  layout(driver.full_name, `Employee ID ${driver.employee_id}`, `<section class="detail-grid"><article class="panel"><div class="panel-heading"><h2>Account</h2>${badge(driver.status)}</div><dl><dt>Activation</dt><dd>${escapeHtml(driver.activation.status)}</dd>${driver.activation.expires_at ? `<dt>Code expires</dt><dd>${formatDate(driver.activation.expires_at)}</dd>` : ''}<dt>Phone</dt><dd>${escapeHtml(driver.phone || '—')}</dd><dt>Notes</dt><dd>${escapeHtml(driver.notes || '—')}</dd></dl><div class="actions">${driver.status === 'disabled' ? '<button data-action="reactivate">Reactivate</button>' : '<button class="danger" data-action="disable">Disable</button>'}${driver.status === 'pending_activation' ? '<button class="secondary" data-action="activation-code">Generate / Reset Activation Code</button>' : ''}<button class="danger" data-delete-driver>Delete Driver</button></div><div id="one-time-code"></div></article><article class="panel"><div class="panel-heading"><h2>Current assignment</h2>${driver.status === 'active' ? `<a class="button secondary" href="/deliveries?driver_id=${driver.id}">Assign Delivery</a>` : ''}</div>${assignmentPanel}</article><article class="panel full-span"><h2>Audit history</h2><ol class="audit">${audits.audit.map((item) => `<li><i></i><div><strong>${escapeHtml(statusLabel(item.event_type))}</strong><span>${formatDate(item.created_at)}</span></div></li>`).join('') || '<li>No audit entries.</li>'}</ol></article></section>`);
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
    const typed = window.prompt(`Delete this Driver from active records? Attendance, route, and audit history will be preserved. Cancel any active route first.\n\nType ${driver.full_name} to confirm.`);
    if (typed === null) return;
    if (typed !== driver.full_name) { showToast('Driver name did not match. Nothing was deleted.'); return; }
    button.disabled = true;
    try {
      await api(`/api/manager/drivers/${id}`, { method: 'DELETE' });
      showToast('Driver deleted.', 'success');
      window.location.assign('/drivers');
    } catch (error) { button.disabled = false; showToast(error.message); }
  });
}

function assignmentRows(assignments) {
  if (!assignments.length) return '<tr><td colspan="6"><div class="empty-state"><strong>No delivery assignments yet.</strong><span>Create the first assignment above.</span></div></td></tr>';
  return assignments.map((item) => {
    const statusAction = ['assigned', 'in_progress'].includes(item.status) ? `<div class="actions compact"><select class="status-select" data-status-id="${item.id}"><option value="">Update status…</option>${(item.status === 'assigned' ? ['in_progress', 'completed'] : ['completed']).map((status) => `<option value="${status}">${statusLabel(status)}</option>`).join('')}</select><button class="danger" data-cancel-route="${item.id}">Cancel Route</button></div>` : '—';
    return `<tr><td><a class="table-primary" href="/drivers/${item.driver_id}">${escapeHtml(item.driver_name)}</a><small>${escapeHtml(item.employee_id)}</small></td><td><strong>${escapeHtml(item.location.name)}</strong><small>${escapeHtml(item.location.address || '')}</small></td><td>${formatDate(item.scheduled_at || item.assigned_at)}</td><td>${badge(item.status)}</td><td>${escapeHtml(item.notes || '—')}</td><td>${statusAction}</td></tr>`;
  }).join('');
}

async function deliveriesPage() {
  const query = new URLSearchParams(window.location.search);
  const [deliveryData, locationData, driverData] = await Promise.all([
    api(`/api/manager/deliveries?${query}`), api('/api/manager/locations'), api('/api/manager/drivers'),
  ]);
  const activeDrivers = driverData.drivers.filter((driver) => driver.status === 'active');
  const activeLocations = locationData.locations.filter((location) => location.active);
  const selectedDriver = query.get('driver_id') || '';
  layout('Deliveries', 'Create destinations, assign Drivers, and keep status current.', `<section class="delivery-layout"><article class="panel composer"><div class="panel-heading"><div><p class="eyebrow">Quick assignment</p><h2>New Delivery</h2></div></div><form id="assignment-form"><label>Active Driver<select name="driver_id" required><option value="">Select Driver</option>${activeDrivers.map((driver) => `<option value="${driver.id}" ${selectedDriver === driver.id ? 'selected' : ''}>${escapeHtml(driver.employee_id)} — ${escapeHtml(driver.full_name)}</option>`).join('')}</select></label><label>Active Location<select name="delivery_location_id" required><option value="">Select destination</option>${activeLocations.map((location) => `<option value="${location.id}">${escapeHtml(location.name)}</option>`).join('')}</select></label><label>Scheduled date/time (optional)<input name="scheduled_at" type="datetime-local" /></label><label>Notes (optional)<textarea name="notes" rows="3"></textarea></label><button ${!activeDrivers.length || !activeLocations.length ? 'disabled' : ''}>Assign Delivery</button><p class="form-hint">${!activeDrivers.length ? 'No active Drivers available. ' : ''}${!activeLocations.length ? 'Create an active location first.' : ''}</p><p id="assignment-error" class="error"></p></form></article><article class="panel location-editor"><div class="panel-heading"><div><p class="eyebrow">Destinations</p><h2 id="location-form-title">Create Location</h2></div></div><form id="location-form"><input name="id" type="hidden" /><label>Location name<input name="name" required /></label><label>Address / description<textarea name="address" rows="2"></textarea></label><div class="form-grid"><label>Latitude<input name="latitude" type="number" min="-90" max="90" step="any" required /></label><label>Longitude<input name="longitude" type="number" min="-180" max="180" step="any" required /></label></div><div class="geofence-fields"><label>Attendance radius (meters)<input name="radius_meters" type="number" min="10" max="5000" step="10" value="100" required /></label><label class="radius-slider-label">Adjust boundary<input id="location-radius-slider" type="range" min="10" max="5000" step="10" value="100" /></label></div><div class="actions"><button>Save Location</button><button id="cancel-location-edit" class="secondary" type="button" hidden>Cancel edit</button></div><p id="location-error" class="error"></p></form></article></section><section class="panel delivery-table"><div class="panel-heading"><div><p class="eyebrow">Assignment history</p><h2>Deliveries</h2></div></div><form id="delivery-filter" class="filters inline"><select name="driver_id"><option value="">All Drivers</option>${driverData.drivers.map((driver) => `<option value="${driver.id}" ${query.get('driver_id') === driver.id ? 'selected' : ''}>${escapeHtml(driver.employee_id)} — ${escapeHtml(driver.full_name)}</option>`).join('')}</select><select name="status"><option value="">All statuses</option>${['assigned', 'in_progress', 'completed', 'cancelled'].map((status) => `<option value="${status}" ${query.get('status') === status ? 'selected' : ''}>${statusLabel(status)}</option>`).join('')}</select><input name="date" type="date" value="${escapeHtml(query.get('date') || '')}"/><button>Filter</button></form><div class="table-wrap"><table><thead><tr><th>Driver</th><th>Destination</th><th>Scheduled / Assigned</th><th>Status</th><th>Notes</th><th>Action</th></tr></thead><tbody>${assignmentRows(deliveryData.assignments)}</tbody></table></div></section><section class="panel location-table"><div class="panel-heading"><div><p class="eyebrow">Saved coordinates</p><h2>Delivery Locations</h2></div><span class="count-chip">${locationData.count}</span></div><div class="table-wrap"><table><thead><tr><th>Location</th><th>Coordinates</th><th>Attendance radius</th><th>Status</th><th>Action</th></tr></thead><tbody>${locationData.locations.map((location) => `<tr><td><strong>${escapeHtml(location.name)}</strong><small>${escapeHtml(location.address || 'No description')}</small></td><td>${location.latitude.toFixed(5)}, ${location.longitude.toFixed(5)}</td><td><strong>${location.radius_meters.toLocaleString()} m</strong></td><td>${badge(location.active ? 'active' : 'disabled')}</td><td><div class="actions compact"><button class="secondary" data-edit-location="${location.id}">Edit</button><button class="secondary" data-toggle-location="${location.id}" data-active="${location.active}">${location.active ? 'Disable' : 'Enable'}</button></div></td></tr>`).join('') || '<tr><td colspan="5"><div class="empty-state"><strong>Create your first delivery location.</strong><span>Pin a location and choose its attendance radius.</span></div></td></tr>'}</tbody></table></div></section>`);

  document.querySelector('#assignment-form').addEventListener('submit', async (event) => {
    event.preventDefault();
    const values = Object.fromEntries(new FormData(event.currentTarget));
    if (!values.scheduled_at) values.scheduled_at = null;
    else values.scheduled_at = new Date(values.scheduled_at).toISOString();
    if (!values.notes) values.notes = null;
    try {
      await api('/api/manager/deliveries', { method: 'POST', body: JSON.stringify(values) });
      showToast('Delivery assigned successfully.', 'success');
      await deliveriesPage();
    } catch (error) { document.querySelector('#assignment-error').textContent = error.message; }
  });
  document.querySelectorAll('[data-status-id]').forEach((select) => select.addEventListener('change', async () => {
    if (!select.value) return;
    try {
      await api(`/api/manager/deliveries/${select.dataset.statusId}`, { method: 'PATCH', body: JSON.stringify({ status: select.value }) });
      showToast(`Assignment marked ${statusLabel(select.value)}.`, 'success');
      await deliveriesPage();
    } catch (error) { showToast(error.message); }
  }));
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
    window.location.assign(`/deliveries?${params}`);
  });
  const locationForm = document.querySelector('#location-form');
  const coordinateGrid = locationForm.querySelector('.form-grid');
  coordinateGrid.insertAdjacentHTML('beforebegin', `<div class="location-picker-shell">
    <div class="location-picker-heading">
      <div><strong>Pin the drop-off location</strong><span>Click the map, then drag the pin to fine-tune it.</span></div>
      <button id="clear-location-pin" class="secondary compact-button" type="button">Clear pin</button>
    </div>
    <div id="location-picker-map" class="location-picker-map" aria-label="Drop-off location picker"></div>
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
    pickerStatus.textContent = `Drop-off pinned at ${lat.toFixed(6)}, ${lng.toFixed(6)}.`;
    if (!pickerMap) return true;
    if (!pickerMarker) {
      pickerMarker = L.marker([lat, lng], { draggable: true, icon: pickerIcon(), title: 'Drag to adjust drop-off' }).addTo(pickerMap);
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
    pickerStatus.textContent = `Drop-off pinned at ${lat.toFixed(6)}, ${lng.toFixed(6)} with a ${radius.toLocaleString()} m attendance radius.`;
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
      pickerStatus.textContent = `Drop-off pinned at ${position.lat.toFixed(6)}, ${position.lng.toFixed(6)} with a ${value.toLocaleString()} m attendance radius.`;
    }
  }
  radiusInput.addEventListener('input', () => updateRadius(radiusInput));
  radiusSlider.addEventListener('input', () => updateRadius(radiusSlider));

  function resetLocationForm() {
    locationForm.reset();
    locationForm.elements.id.value = '';
    document.querySelector('#location-form-title').textContent = 'Create Location';
    document.querySelector('#cancel-location-edit').hidden = true;
    clearPicker();
  }
  locationForm.addEventListener('submit', async (event) => {
    event.preventDefault();
    const values = Object.fromEntries(new FormData(locationForm));
    const id = values.id;
    delete values.id;
    values.latitude = Number(values.latitude);
    values.longitude = Number(values.longitude);
    values.radius_meters = Number(values.radius_meters);
    values.address = values.address || null;
    try {
      await api(id ? `/api/manager/locations/${id}` : '/api/manager/locations', { method: id ? 'PATCH' : 'POST', body: JSON.stringify(values) });
      showToast(id ? 'Location updated.' : 'Location created.', 'success');
      await deliveriesPage();
    } catch (error) { document.querySelector('#location-error').textContent = error.message; }
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
    document.querySelector('#location-form-title').textContent = 'Edit Location';
    document.querySelector('#cancel-location-edit').hidden = false;
    locationForm.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }));
  document.querySelectorAll('[data-toggle-location]').forEach((button) => {
    const location = locationData.locations.find((item) => item.id === button.dataset.toggleLocation);
    button.insertAdjacentHTML('afterend', `<button class="danger" data-delete-location="${location.id}">Delete</button>`);
  });
  document.querySelectorAll('[data-toggle-location]').forEach((button) => button.addEventListener('click', async () => {
    try {
      await api(`/api/manager/locations/${button.dataset.toggleLocation}`, { method: 'PATCH', body: JSON.stringify({ active: button.dataset.active !== 'true' }) });
      showToast('Location status updated.', 'success');
      await deliveriesPage();
    } catch (error) { showToast(error.message); }
  }));
  document.querySelectorAll('[data-delete-location]').forEach((button) => button.addEventListener('click', async () => {
    const location = locationData.locations.find((item) => item.id === button.dataset.deleteLocation);
    const typed = window.prompt(`Delete this Location from active records? Attendance and route history will be preserved. Cancel any active route first.\n\nType ${location.name} to confirm.`);
    if (typed === null) return;
    if (typed !== location.name) { showToast('Location name did not match. Nothing was deleted.'); return; }
    button.disabled = true;
    try {
      await api(`/api/manager/locations/${location.id}`, { method: 'DELETE' });
      showToast('Location deleted.', 'success');
      await deliveriesPage();
    } catch (error) { button.disabled = false; showToast(error.message); }
  }));
}

async function attendancePage() {
  const params = new URLSearchParams(window.location.search);
  const [records, drivers] = await Promise.all([api(`/api/manager/attendance?${params}`), api('/api/manager/drivers')]);
  const rows = records.attendance.map((item) => `<tr><td>${formatDate(item.captured_at_utc)}</td><td><strong>${escapeHtml(item.driver_name)}</strong><small>${escapeHtml(item.employee_id)}</small></td><td>${escapeHtml(item.site_name || 'Unknown location')}</td><td>${item.face_score.toFixed(4)}</td><td>${item.distance_meters.toFixed(1)} m</td><td>${formatDate(item.server_received_at)}</td></tr>`).join('') || '<tr><td colspan="6"><div class="empty-state"><strong>No attendance found.</strong><span>Synchronized records will appear here.</span></div></td></tr>';
  layout('Attendance', 'Synchronized records accepted from active authenticated Drivers.', `<form class="filters panel" id="attendance-filter"><input name="date" type="date" value="${escapeHtml(params.get('date') || '')}"/><select name="driver_id"><option value="">All Drivers</option>${drivers.drivers.map((driver) => `<option value="${driver.id}" ${params.get('driver_id') === driver.id ? 'selected' : ''}>${escapeHtml(driver.employee_id)} — ${escapeHtml(driver.full_name)}</option>`).join('')}</select><button>Filter</button></form><section class="panel table-wrap"><table><thead><tr><th>Captured</th><th>Driver</th><th>Site</th><th>Face score</th><th>Distance</th><th>Received</th></tr></thead><tbody>${rows}</tbody></table></section>`);
  document.querySelector('#attendance-filter').addEventListener('submit', (event) => {
    event.preventDefault();
    const query = new URLSearchParams(new FormData(event.currentTarget));
    [...query].forEach(([key, value]) => { if (!value) query.delete(key); });
    window.location.assign(`/attendance?${query}`);
  });
}

async function auditPage() {
  const data = await api('/api/manager/audit');
  const rows = data.audit.map((item) => `<tr><td>${formatDate(item.created_at)}</td><td>${escapeHtml(statusLabel(item.event_type))}</td><td>${item.driver_name ? `<a class="table-primary" href="/drivers/${item.target_account_id}">${escapeHtml(item.driver_name)}</a><small>${escapeHtml(item.employee_id)}</small>` : '<span class="muted">Fleet Manager</span>'}</td></tr>`).join('') || '<tr><td colspan="3"><div class="empty-state"><strong>No audit entries.</strong></div></td></tr>';
  layout('Audit', 'Recent account and delivery workflow activity.', `<section class="panel table-wrap"><table><thead><tr><th>Time</th><th>Event</th><th>Target</th></tr></thead><tbody>${rows}</tbody></table></section>`);
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
