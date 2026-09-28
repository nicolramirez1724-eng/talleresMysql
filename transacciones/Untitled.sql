-- ==============================================================================
-- TALLER PRÁCTICO: OPTIMIZACIÓN DE CONSULTAS Y RENDIMIENTO EN MYSQL (BancoDB)
-- ==============================================================================
-- Objetivo: Que los estudiantes diagnostiquen consultas lentas usando EXPLAIN ANALYZE,
-- identifiquen lecturas completas de tabla (Table Scans), reescriban consultas
-- de forma sargable y apliquen índices compuestos y cubrientes sobre la base de datos bancaria.
-- ==============================================================================

CREATE DATABASE IF NOT EXISTS BancoDB;
USE BancoDB;

-- ------------------------------------------------------------------------------
-- PARTE 0: ESTRUCTURA DE TABLAS E POBLAMIENTO DE DATOS MASIVOS
-- ------------------------------------------------------------------------------

DROP TABLE IF EXISTS historial_transferencias;
DROP TABLE IF EXISTS cuentas;

CREATE TABLE cuentas (
    id_cuenta INT PRIMARY KEY AUTO_INCREMENT,
    titular VARCHAR(100) NOT NULL,
    tipo_cuenta VARCHAR(20) NOT NULL DEFAULT 'Ahorros',
    saldo DECIMAL(12,2) NOT NULL DEFAULT 0.00,
    estado VARCHAR(20) NOT NULL DEFAULT 'Activa',
    fecha_apertura DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE historial_transferencias (
    id_transferencia INT AUTO_INCREMENT PRIMARY KEY,
    cuenta_origen INT NOT NULL,
    cuenta_destino INT NOT NULL,
    monto DECIMAL(12, 2) NOT NULL,
    estado_transferencia VARCHAR(20) NOT NULL DEFAULT 'Exitosa',
    fecha DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (cuenta_origen) REFERENCES cuentas(id_cuenta),
    FOREIGN KEY (cuenta_destino) REFERENCES cuentas(id_cuenta)
);

-- Procedimiento auxiliar para generar un volumen masivo de prueba
DELIMITER //
CREATE PROCEDURE CargarDatosPrueba()
BEGIN
    DECLARE i INT DEFAULT 1;

    WHILE i <= 1000 DO
        INSERT INTO cuentas (titular, tipo_cuenta, saldo, estado, fecha_apertura)
        VALUES (
            CONCAT('Cliente_', i),
            IF(i % 2 = 0, 'Ahorros', 'Corriente'),
            ROUND(RAND() * 10000000, 2),
            IF(i % 10 = 0, 'Bloqueada', 'Activa'),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 365) DAY)
        );
        SET i = i + 1;
    END WHILE;

    SET i = 1;
    WHILE i <= 10000 DO
        INSERT INTO historial_transferencias (cuenta_origen, cuenta_destino, monto, estado_transferencia, fecha)
        VALUES (
            FLOOR(1 + RAND() * 999),
            FLOOR(1 + RAND() * 999),
            ROUND(1000 + RAND() * 500000, 2),
            IF(i % 15 = 0, 'Fallida', 'Exitosa'),
            DATE_SUB(NOW(), INTERVAL FLOOR(RAND() * 180) DAY)
        );
        SET i = i + 1;
    END WHILE;
END //
DELIMITER ;

CALL CargarDatosPrueba();
DROP PROCEDURE IF EXISTS CargarDatosPrueba;


-- ==============================================================================
-- PARTE 1: DEMOSTRACIÓN GUIADA EN CLASE (PROFESOR)
-- ==============================================================================

EXPLAIN ANALYZE
SELECT id_transferencia, cuenta_origen, monto, fecha
FROM historial_transferencias
WHERE estado_transferencia = 'Exitosa'
  AND fecha >= '2026-01-01 00:00:00';

CREATE INDEX idx_transf_estado_fecha ON historial_transferencias(estado_transferencia, fecha);

EXPLAIN ANALYZE
SELECT id_transferencia, cuenta_origen, monto, fecha
FROM historial_transferencias
WHERE estado_transferencia = 'Exitosa'
  AND fecha >= '2026-01-01 00:00:00';


-- ==============================================================================
-- PARTE 2: EJERCICIOS PRÁCTICOS (RESUELTOS)
-- ==============================================================================

-- ------------------------------------------------------------------------------
-- EJERCICIO 1: Diagnóstico de "Non-Sargable Query" (Uso de Funciones en WHERE)
-- ------------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT * 
FROM historial_transferencias 
WHERE DATE(fecha) = '2026-02-15';

-- [ESCRIBE TU SOLUCIÓN AQUÍ]

-- 1. DATE(fecha) envuelve la columna en una función, así que MySQL no puede usar
--    ningún índice sobre "fecha": tiene que calcular DATE() fila por fila (table scan).
--    idx_transf_estado_fecha tampoco sirve porque no filtramos por estado_transferencia.

-- 2. Reescritura sargable, usando un rango de fechas sin envolver la columna:
CREATE INDEX idx_transf_fecha ON historial_transferencias(fecha);

-- 3. Comparación de planes:
EXPLAIN ANALYZE
SELECT * 
FROM historial_transferencias 
WHERE fecha >= '2026-02-15 00:00:00' 
  AND fecha <  '2026-02-16 00:00:00';


-- ------------------------------------------------------------------------------
-- EJERCICIO 2: Optimización mediante Índices Cubrientes (Covering Index)
-- ------------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT titular, saldo, tipo_cuenta
FROM cuentas
WHERE estado = 'Activa';

-- [ESCRIBE TU SOLUCIÓN AQUÍ]

-- 1. SELECT * obligaría a MySQL a volver a la tabla base por columnas que no están
--    en ningún índice (id_cuenta, fecha_apertura). Pidiendo solo titular, saldo y
--    tipo_cuenta, la consulta puede resolverse enteramente desde el índice.

-- 2. Índice cubriente (columna del WHERE primero, luego las columnas retornadas):
CREATE INDEX idx_cuentas_estado_cover 
ON cuentas (estado, saldo, tipo_cuenta, titular);

-- 3. Verificación:
EXPLAIN ANALYZE
SELECT titular, saldo, tipo_cuenta
FROM cuentas
WHERE estado = 'Activa';
-- Debería mostrar "Using index" sin acceso adicional a la tabla base.


-- ------------------------------------------------------------------------------
-- EJERCICIO 3: Optimización de Filtros Combinados y JOINs
-- ------------------------------------------------------------------------------
EXPLAIN ANALYZE
SELECT c.id_cuenta, c.titular, ht.id_transferencia, ht.monto, ht.fecha
FROM cuentas c
JOIN historial_transferencias ht ON c.id_cuenta = ht.cuenta_origen
WHERE c.estado = 'Activa'
  AND ht.monto > 300000.00;

-- [ESCRIBE TU SOLUCIÓN AQUÍ]

-- 1. El full table scan aparece tanto en cuentas (filtro por estado sin índice)
--    como en historial_transferencias (filtro por monto sin índice).

-- 2. Índices para optimizar el JOIN y los filtros:
CREATE INDEX idx_cuentas_estado ON cuentas(estado, id_cuenta);
CREATE INDEX idx_transf_origen_monto ON historial_transferencias(cuenta_origen, monto);

-- 3. Justificación del orden: cuenta_origen va primero porque es una igualdad
--    (se usa para emparejar filas en el JOIN); monto va al final porque es un
--    rango. Regla general de índices compuestos: igualdades antes que rangos.

EXPLAIN ANALYZE
SELECT c.id_cuenta, c.titular, ht.id_transferencia, ht.monto, ht.fecha
FROM cuentas c
JOIN historial_transferencias ht ON c.id_cuenta = ht.cuenta_origen
WHERE c.estado = 'Activa'
  AND ht.monto > 300000.00;

-- NOTA: el enunciado menciona "últimos 30 días" pero la consulta base no filtra
-- por fecha. Si se pide, agregar: AND ht.fecha >= NOW() - INTERVAL 30 DAY


-- ==============================================================================
-- FIN DEL TALLER
-- ==============================================================================