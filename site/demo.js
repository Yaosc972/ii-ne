const demo = document.querySelector('.demo');
const descriptions = {
  capture: '框选画面，在选区旁直接标注。',
  pin: '把选区贴在桌面上，切换窗口也能继续对照。',
  ocr: '选中画上的题字，提取为可以复制的文本。'
};
for (const button of demo.querySelectorAll('button')) {
  button.addEventListener('click', () => {
    const mode = button.dataset.mode;
    demo.dataset.mode = mode;
    for (const choice of demo.querySelectorAll('button')) {
      choice.setAttribute('aria-pressed', String(choice === button));
    }
    document.querySelector('#demo-description').textContent = descriptions[mode];
  });
}
const copy = document.querySelector('#copy');
copy.addEventListener('click', async () => {
  const code = document.querySelector('#commands');
  const status = document.querySelector('#copy-status');
  try {
    await navigator.clipboard.writeText(code.textContent);
    copy.textContent = '已复制';
    status.textContent = '已复制安装命令';
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(code);
    selection.removeAllRanges();
    selection.addRange(range);
    copy.textContent = '请手动复制';
    status.textContent = '命令已选中，请手动复制';
  }
});
