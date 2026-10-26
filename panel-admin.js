(() => {
  const labels = {
    overview: 'Resumen general', businesses: 'Negocios', products: 'Productos', orders: 'Pedidos',
    users: 'Usuarios y roles', reports: 'Reportes y estadísticas', legal: 'Políticas legales',
    security: 'Seguridad y actividad', technical: 'Estado técnico'
  };
  const nav = document.querySelector('#sideNav');
  const title = document.querySelector('#pageTitle');
  const toast = document.querySelector('#toast');
  let toastTimer;
  function notify(message) {
    toast.textContent = message;
    toast.classList.add('show');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => toast.classList.remove('show'), 3200);
  }
  function showView(key) {
    if (!labels[key]) return;
    document.querySelectorAll('.view').forEach(el => el.classList.toggle('active-view', el.id === `view-${key}`));
    document.querySelectorAll('.nav-item').forEach(el => el.classList.toggle('active', el.dataset.view === key));
    title.textContent = labels[key];
    window.scrollTo({ top: 0, behavior: 'smooth' });
  }
  nav.addEventListener('click', event => {
    const button = event.target.closest('[data-view]');
    if (button) showView(button.dataset.view);
  });
  document.addEventListener('click', event => {
    const jump = event.target.closest('[data-jump]');
    if (jump) showView(jump.dataset.jump);
    const demo = event.target.closest('[data-demo]');
    if (demo) notify(`${demo.dataset.demo}: función de demostración. No se guardó ningún cambio.`);
  });
  document.querySelectorAll('[data-filter]').forEach(input => {
    input.addEventListener('input', () => {
      const table = document.getElementById(input.dataset.filter);
      if (!table) return;
      const query = input.value.trim().toLocaleLowerCase('es');
      table.querySelectorAll('tbody tr').forEach(row => {
        row.hidden = !row.textContent.toLocaleLowerCase('es').includes(query);
      });
    });
  });
  document.querySelector('#exportBtn').addEventListener('click', () => {
    const active = document.querySelector('.view.active-view');
    const content = `MiEje Market — ${labels[active?.id.replace('view-', '')] || 'Panel'}\n\nPrototipo visual. No contiene datos reales ni registros operativos.\n\nEsta exportación es solo una nota de demostración.`;
    const blob = new Blob([content], { type: 'text/plain;charset=utf-8' });
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a'); link.href = url; link.download = 'mieje-market-vista-demo.txt'; link.click();
    URL.revokeObjectURL(url);
  });
})();
