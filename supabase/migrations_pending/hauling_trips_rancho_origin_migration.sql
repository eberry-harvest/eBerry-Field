-- ============================================================
-- V21_00_2: Migration — hauling_trips.rancho_origin
-- Project: opdwtijyropzoyeseoij
-- Tenant: 00000000-0000-0000-0000-000000000001
-- Purpose: Link each hauling trip to the rancho the hauler
--          is picking up from (rancho de origen).
-- IDEMPOTENT: safe to run multiple times (ADD COLUMN IF NOT EXISTS)
-- DO NOT APPLY without Cyndy's review.
-- ============================================================

-- Agregar columna rancho_origin a hauling_trips (idempotente)
ALTER TABLE public.hauling_trips
  ADD COLUMN IF NOT EXISTS rancho_origin TEXT DEFAULT NULL;

-- Comentario descriptivo en la columna
COMMENT ON COLUMN public.hauling_trips.rancho_origin
  IS 'V21_00_2: Rancho de origen del viaje de acarreo. '
     'Seleccionado por el hauler en la pantalla de inicio del viaje. '
     'Coincide con los nombres de rancho del array _ranchos[] del surquero activo.';

-- Índice para consultas frecuentes por rancho de origen
CREATE INDEX IF NOT EXISTS idx_hauling_trips_rancho_origin
  ON public.hauling_trips (rancho_origin)
  WHERE rancho_origin IS NOT NULL;

-- Verificación: mostrar la estructura de la columna
-- SELECT column_name, data_type, column_default, is_nullable
-- FROM information_schema.columns
-- WHERE table_schema = 'public'
--   AND table_name = 'hauling_trips'
--   AND column_name = 'rancho_origin';
