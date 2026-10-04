const command = document.querySelector('#install-command');
const button = document.querySelector('#copy');
const status = document.querySelector('#copy-status');
button.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(command.textContent);
    status.textContent = 'Copied.';
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(command);
    selection.removeAllRanges();
    selection.addRange(range);
    command.focus();
    status.textContent = 'Command selected. Copy it manually.';
  }
});
