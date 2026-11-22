# Fuerza bruta en el login

> Regla: `fuerza-bruta` (`faclab.auth.login.attempts` con `result` en `invalid` o `locked`) ·
> Severidad: **advertencia** · Dashboard: *Faclab · Calidad de operaciones*, panel «Intentos de login
> fallidos»

## Síntoma

Más de 50 intentos de login fallidos en 5 minutos. El core ya bloquea:

- cada usuario tras `LOGIN_MAX_FAILURES_PER_USER` (5);
- cada IP tras `LOGIN_MAX_FAILURES_PER_IP` (20);

los dos en `LOGIN_FAILURE_WINDOW_SECONDS` (15 min) y durante `LOGIN_LOCKOUT_SECONDS` (15 min).
Muchos `locked` indican que el bloqueo está actuando. Muchos `invalid` de IPs distintas indican un
ataque distribuido que el bloqueo por IP no frena.

## Diagnóstico

1. Los intentos quedan en `login_failures` del core (usuario intentado e IP, sin contraseñas):

   ```sql
   SELECT ip_address, count(*), count(DISTINCT username) FROM login_failures
   WHERE attempted_at > now() - interval '30 minutes' GROUP BY 1 ORDER BY 2 DESC LIMIT 20;
   ```
2. ¿Usuarios que existen? Un usuario real con muchos intentos puede ser alguien que olvidó su
   contraseña o un ataque dirigido.
3. En *Traces*, `http.route = /api/auth/login` con 401 y 429 muestra el ritmo y los orígenes.

## Acción

- **Pocas IPs:** bloquearlas en el proxy de entrada (Caddy, S8.1) o en el firewall del VPS.
- **Muchas IPs:** bajar los umbrales de bloqueo por usuario o limitar la ruta en el proxy.
- **Un usuario real bloqueado:** que espere el bloqueo o que un administrador le restablezca la
  contraseña. Un restablecimiento revoca sus sesiones.

## Escalamiento

Si hay inicios de sesión exitosos de las mismas IPs del ataque, tratarlo como un incidente de
seguridad: escalar de inmediato, revocar las sesiones del usuario y forzar el cambio de contraseña.

## Prueba controlada

Ver [pruebas de alertas](../signoz/pruebas-de-alertas.md#fuerza-bruta).
