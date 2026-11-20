interface Window {
  __tunerBoxServerStartedByApp?: boolean;
}

declare module 'virtual:changelog' {
  const raw: string;
  export default raw;
}
