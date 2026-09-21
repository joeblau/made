import { initOpenNextCloudflareForDev } from '@opennextjs/cloudflare';
import type { NextConfig } from 'next';

void initOpenNextCloudflareForDev();

const nextConfig: NextConfig = {
  poweredByHeader: false,
};

export default nextConfig;
