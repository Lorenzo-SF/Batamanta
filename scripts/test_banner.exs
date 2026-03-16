# Script para probar el banner
# Usage: mix run scripts/test_banner.exs

alias Batamanta.Banner

messages = [
  "🖥️  OS: linux",
  "⚙️  Architecture: x86_64",
  "📦 Type: glibc",
  "🔢 ERTS: 28.0"
]

# Mostrar banner con streaming de mensajes
ctx = Banner.show_with_context(messages, show_banner: true)

# Simular logs adicionales en tiempo real
Process.sleep(500)
Banner.append_line(ctx, "Procesando...")
Process.sleep(500)
Banner.append_line(ctx, "Completado!")

# Cambiar imagen al final (simular éxito)
Process.sleep(500)
Banner.set_image(ctx, :success)

Process.sleep(1000)

