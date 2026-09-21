import { defineCloudflareConfig } from '@opennextjs/cloudflare';

const config = defineCloudflareConfig();
config.buildCommand = 'bun run build:next';

export default config;
