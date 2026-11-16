# Implementación visual de MiEje Market

Fecha: 16 de noviembre de 2026  
Rama: `correcciones-funcionales`

## Alcance implementado

Se incorporó una capa visual nueva para la tienda pública y los tres paneles operativos, sin modificar consultas, permisos, autenticación, funciones SQL ni flujos de negocio.

- Tienda pública: `styles.css` + `index.html`.
- Panel técnico superior: `panel-tecnico.html` + `panel-live.css`.
- Panel de administrador de negocio: `panel-negocio.html` + `panel-live.css`.
- Panel de empleados: `panel-personal.html` + `panel-live.css`.
- Animaciones progresivas y accesibles: `visual-motion.js`.

## Regla de uniformidad por rol

Los paneles de administrador y de empleados utilizan una sola hoja de estilos compartida y sus respectivas plantillas operativas. Las cuentas nuevas creadas desde el panel técnico se resuelven por su rol y pertenencia al negocio; no se crea una plantilla ni un tema individual por usuario.

Por tanto:
- Todos los administradores de negocio reciben la misma estructura visual, navegación, botones, formularios, tablas y componentes. Cambian los datos del negocio y los permisos, no el diseño.
- Todos los empleados reciben la misma estructura visual, navegación, botones y componentes operativos. Cambian los datos del negocio y los permisos, no el diseño.
- El panel técnico conserva su identidad dentro del mismo sistema visual, con navegación y herramientas propias del rol técnico.

## Dirección visual

- Identidad de marca basada en verde profundo, verde natural, fondos claros y acento lima.
- Interfaz limpia y ordenada, con jerarquía tipográfica clara.
- Tarjetas, tablas, formularios y botones con bordes, radios y sombras coherentes.
- Navegación lateral adaptable a pantallas pequeñas.
- Estados de foco visibles y respeto por `prefers-reduced-motion`.
- Aparición progresiva al desplazarse, incluyendo tarjetas y contenido insertado dinámicamente.

## Fuera de alcance

`panel-admin.html` continúa siendo un prototipo visual desconectado. No es el panel operativo de administrador. El panel real del administrador de cada negocio es `panel-negocio.html`.

## Verificación realizada

- Se comprobó que los tres paneles operativos enlazan `panel-live.css`.
- Se comprobó que las cuatro páginas (pública y tres paneles) enlazan `visual-motion.js`.
- Se verificó balance de llaves en ambos archivos CSS.
- Se verificó que la animación tiene alternativa para usuarios que prefieren movimiento reducido.
- No se ejecutaron pruebas de navegador ni pruebas visuales en dispositivos reales.
- No se modificó `main`, no se publicó GitHub Pages y no se modificó Supabase.

## Pendiente de validación visual

Abrir la rama en un entorno de previsualización y revisar escritorio, tablet y móvil; comprobar menú lateral, tablas anchas, formularios extensos, tarjetas dinámicas, estados vacíos, imágenes y flujos de carrito/checkout. Ajustar cualquier desbordamiento o contraste observado antes de promover los cambios.
