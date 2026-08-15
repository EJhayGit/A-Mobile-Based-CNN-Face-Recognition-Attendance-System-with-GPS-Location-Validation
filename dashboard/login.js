function toggleTheme() {
  const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
  document.documentElement.dataset.theme = next;
  localStorage.setItem('fleet-theme', next);
}

document.querySelector('#login-theme').addEventListener('click', toggleTheme);
document.querySelector('#login-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const error = document.querySelector('#login-error');
  error.textContent = '';
  const form = new FormData(event.currentTarget);
  try {
    const response = await fetch('/api/manager/auth/login', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ login_id: form.get('login_id'), password: form.get('password') }),
    });
    if (response.ok) window.location.assign('/');
    else if (response.status === 429) error.textContent = 'Too many attempts. Try again later.';
    else error.textContent = 'Invalid login credentials';
  } catch (_) {
    error.textContent = 'The server is unavailable. Try again shortly.';
  }
});
