<script setup lang="ts">
import { useData } from 'vitepress'

const { theme } = useData()
</script>

<template>
  <a class="hero-badge" href="https://github.com/ecorreiax/ffmig">
    <span class="hero-badge-dot" />
    <span>v{{ theme.version }}</span>
    <span class="hero-badge-sep" />
    <span>Early development · PostgreSQL</span>
  </a>
</template>
