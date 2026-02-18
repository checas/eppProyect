import { spawn } from 'node:child_process';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import fs from 'node:fs';
import { chromium } from 'playwright';

const cwd = process.cwd();

const run = (cmd, args, opts = {}) =>
	new Promise((resolve, reject) => {
		const child = spawn(cmd, args, {
			cwd,
			stdio: 'inherit',
			shell: process.platform === 'win32',
			...opts,
		});
		child.on('exit', (code) => {
			if (code === 0) resolve();
			else reject(new Error(`${cmd} ${args.join(' ')} exited with code ${code}`));
		});
		child.on('error', reject);
	});

const waitForPreviewReady = (child) =>
	new Promise((resolve, reject) => {
		let resolved = false;
		const onData = (buf) => {
			const s = buf.toString();
			if (!resolved && (s.includes('Local') || s.includes('http://localhost'))) {
				resolved = true;
				resolve();
			}
		};

		child.stdout?.on('data', onData);
		child.stderr?.on('data', onData);
		child.on('error', reject);
		child.on('exit', (code) => {
			if (!resolved) reject(new Error(`astro preview exited before ready (code ${code ?? 'unknown'})`));
		});

		setTimeout(() => {
			if (!resolved) reject(new Error('Timed out waiting for astro preview to be ready'));
		}, 20000);
	});

const main = async () => {
	const port = process.env.CATALOGO_PDF_PORT || '4322';
	const url = `http://127.0.0.1:${port}/catalogo-pdf`;
	const outFileUrl = new URL('../public/catalogo.pdf', import.meta.url);
	const outPath = fileURLToPath(outFileUrl);

	await run('npm', ['run', 'build']);

	const preview = spawn(
		'npm',
		['run', 'preview', '--', '--host', '127.0.0.1', '--port', port],
		{
			cwd,
			stdio: ['ignore', 'pipe', 'pipe'],
			shell: process.platform === 'win32',
		}
	);

	const cleanup = () => {
		try {
			preview.kill();
		} catch {
			// ignore
		}
	};
	process.on('exit', cleanup);
	process.on('SIGINT', () => {
		cleanup();
		process.exit(1);
	});

	try {
		await waitForPreviewReady(preview);

		const browser = await chromium.launch();
		const page = await browser.newPage({ viewport: { width: 1280, height: 720 } });
		await page.goto(url, { waitUntil: 'networkidle' });
		await page.emulateMedia({ media: 'print' });

		const logoFilePath = fileURLToPath(new URL('../src/assets/logo-horizontal.png', import.meta.url));
		const logoBuf = fs.readFileSync(logoFilePath);
		const logoDataUrl = `data:image/png;base64,${logoBuf.toString('base64')}`;
		await page.addStyleTag({
			content: `@page { margin: 28mm 12mm 20mm 12mm; }`,
		});
		await page.evaluate(() => {
			document.documentElement.style.setProperty('counter-reset', 'none');
		});

		const headerTemplate = `
			<div style="width: 100%; padding: 0 12mm; font-size: 10px;">
				<div style="display:flex; align-items:center; height: 18mm;">
					<img src="${logoDataUrl}" style="height: 10mm; width: auto;" />
				</div>
			</div>
		`;

		const footerTemplate = `
			<div style="width: 100%; padding: 0 12mm; font-size: 10px; color: #475569;">
				<div style="border-top: 1px solid #e2e8f0; padding-top: 4mm; display:flex; align-items:center; justify-content: space-between;">
					<div style="white-space: nowrap;">WhatsApp: +54 9 2644 399189 <span style="color:#cbd5e1; padding: 0 6px;">|</span> contacto@epptotal.com.ar</div>
					<div style="white-space: nowrap;">Página <span class="pageNumber"></span></div>
				</div>
			</div>
		`;

		await page.pdf({
			path: outPath,
			format: 'A4',
			printBackground: true,
			displayHeaderFooter: true,
			headerTemplate,
			footerTemplate,
			margin: { top: '28mm', right: '12mm', bottom: '20mm', left: '12mm' },
		});

		await browser.close();
		console.log(`\nOK: PDF generado en ${outPath}`);
	} finally {
		cleanup();
	}
};

main().catch((err) => {
	console.error(err);
	process.exit(1);
});
