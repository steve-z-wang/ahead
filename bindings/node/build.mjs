import {execFileSync} from 'node:child_process';
import {copyFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
const directory = fileURLToPath(new URL('.', import.meta.url));
const release=process.argv.includes('--release');
execFileSync('cargo', ['build', ...(release?['--release']:[]), '--locked', '--manifest-path', `${directory}Cargo.toml`], {stdio:'inherit'});
const filename = process.platform === 'darwin' ? 'liblfs_node.dylib' : process.platform === 'win32' ? 'lfs_node.dll' : 'liblfs_node.so';
copyFileSync(`${directory}target/${release?'release':'debug'}/${filename}`, `${directory}lfs-node.node`);
