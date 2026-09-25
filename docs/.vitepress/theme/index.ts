import { h } from 'vue'
import DefaultTheme from 'vitepress/theme'
import '@fontsource-variable/geist'
import '@fontsource-variable/geist-mono'
import HeroBadge from './HeroBadge.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  Layout: () =>
    h(DefaultTheme.Layout, null, {
      'home-hero-info-before': () => h(HeroBadge),
    }),
}
