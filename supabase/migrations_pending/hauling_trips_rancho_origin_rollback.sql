-- ============================================================
-- V21_00_2: ROLLBACK — hauling_trips.rancho_origin
-- Project: opdwtijyropzoyeseoij
-- Tenant: 00000000-0000-0000-0000-000000000001
-- ADVERTENCIA: Este script elimina la columna rancho_origin
-- y TODOS sus datos de forma irreversible.
-- Ejecutar SOLO si es necesario revertir V21_00_2 por completo.
-- ============================================================

-- Eliminar índice primero
DROP INDEX IF EXISTS public.idx_hauling_trips_rancho_origin;

-- Eliminar columna (y sus datos)
ALTER TABLE public.hauling_trips
  DROP COLUMN IF EXISTS rancho_origin;

-- Verificación post-rollback:
-- SELECT column_name FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name = 'hauling_trips'
--   AND column_name = 'rancho_origin';
-- (debe retornar 0 filas)
