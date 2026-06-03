// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
	// ⚠️【重要】ご自身のGitHubユーザー名とリポジトリ名（例: haruto-marumo / AtmosFiore）に書き換えてください
	site: 'https://haru-425.github.io',
	base: '/AtmosFiore',

	integrations: [
		starlight({
			title: 'AtmosFiore Docs & Portfolio',
			// 室内シェーダーの「灯火と闇」を表現するカスタムCSS
			customCss: ['./src/styles/custom.css'],

			// 【最新仕様】配列型（[]）の中にリンクをオブジェクトとして格納します
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/haru-425/AtmosFiore'
				}
			],
			sidebar: [
				{
					label: 'プロジェクト・自己紹介',
					items: [
						{ autogenerate: { directory: 'guides' } } // guidesフォルダ内を自動メニュー化
					],
				},
				{
					label: 'コア技術・実装解説',
					items: [
						{ autogenerate: { directory: 'reference' } } // referenceフォルダ内を自動メニュー化
					],
				},
			],
		}),
	],
});