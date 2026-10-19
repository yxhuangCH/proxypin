import fs from 'fs'
import path from 'path'
import { appTasks } from '@ohos/hvigor-ohos-plugin';
import { flutterHvigorPlugin } from 'flutter-hvigor-plugin';

const signingFile = process.env.PROXYPIN_OHOS_SIGNING_CONFIG
  ?? path.join(__dirname, 'signing.local.json');

const overrides: Record<string, unknown> = {};
if (fs.existsSync(signingFile)) {
  const { material, type } = JSON.parse(fs.readFileSync(signingFile, 'utf8'));
  overrides.signingConfig = { material, type };
}

export default {
    system: appTasks,  /* Built-in plugin of Hvigor. It cannot be modified. */
    plugins:[flutterHvigorPlugin(path.dirname(__dirname))],         /* Custom plugin to extend the functionality of Hvigor. */
    config: { ohos: { overrides } }
}
