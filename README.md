# Procesador de boletas IA

Aplicación web en Ruby on Rails para subir boletas chilenas, vouchers o comprobantes de compra en PDF, JPG o PNG, procesarlos con IA/OCR, revisar los datos detectados y guardar la compra en PostgreSQL.

## Enlaces

🚀 **[Demo en producción](https://lector-boletas-ia.onrender.com/)**

🎨 **[Maquetación en Figma](https://www.figma.com/design/yEgnYVwzzXBq6yYweqRSvD/Extractor-de-boletas-IA?node-id=0-1&t=pdqIjuQUgewHjxPn-1)**

Desplegada en Render con PostgreSQL en Supabase.

La demo puede estar protegida con una clave de acceso compartida, entregada directamente por seguridad.

## Funcionalidades

- Subida de archivos PDF, JPG y PNG.
- Procesamiento de boletas, facturas, tickets y vouchers de compra.
- Clasificación del tipo de documento antes de extraer datos.
- Extracción de comercio, RUT, número de documento, fecha, total, IVA e ítems.
- Formulario editable antes de guardar.
- Validaciones para evitar registros vacíos o incompletos.
- Advertencia no bloqueante si la suma de ítems no coincide con el total.
- Listado, búsqueda, edición y eliminación de compras.
- Acceso protegido opcional por clave compartida.

## Stack

- Ruby `ruby-4.0.5`
- Rails `~> 8.1.3`
- PostgreSQL
- Supabase como base de datos en producción
- Render para despliegue
- Figma para maquetación
- Gemini para análisis visual de documentos
- OCR.space para extracción OCR
- Groq para estructurar texto extraído por OCR

## Requisitos

- Ruby 4.0.5
- PostgreSQL
- Claves de API para Gemini, Groq y OCR.space

## Instalación Local

1. Instalar dependencias:

```bash
bundle install
```

2. Crear archivo de variables de entorno:

```bash
cp .env.example .env
```

3. Configurar `.env` con las variables necesarias.

4. Crear y migrar la base de datos:

```bash
bundle exec rails db:create db:migrate
```

5. Levantar la aplicación:

```bash
bundle exec rails server
```

La aplicación queda disponible en `http://localhost:3000`.

## Variables de Entorno

El proyecto incluye `.env.example` como referencia.

Variables principales:

```txt
DATABASE_PASSWORD=
DATABASE_URL=
GEMINI_API_KEY=
GROQ_API_KEY=
OCR_SPACE_API_KEY=
AI_ENGINE=auto
APP_ACCESS_LOCK_ENABLED=false
APP_ACCESS_PASSWORD=
```

Nota: En desarrollo local la aplicación utiliza DATABASE_PASSWORD junto con la configuración de database.yml. En producción, la conexión se realiza mediante DATABASE_URL apuntando a la base de datos de Supabase.

## Uso

1. Entrar a la aplicación.
2. Subir una boleta, factura, ticket, voucher o comprobante de compra.
3. La aplicación procesa el archivo con IA/OCR(Identificado por el sistema o seleccionado por el usuario).
4. Se muestra un formulario precargado con los datos detectados.
5. El usuario revisa, corrige o completa los campos faltantes.
6. La compra se guarda en PostgreSQL.
7. Las compras guardadas se pueden consultar, editar o eliminar.

## Validaciones al Guardar

Para evitar registros vacíos, al guardar se exige:

- Comercio o RUT del comercio. Basta con uno de los dos.
- Número de documento.
- Fecha de compra.
- Total mayor que `0`.

## Cómo se Resolvió el Problema

El procesamiento utiliza dos métodos, priorizando un buen uso de recursos. Cuando el texto puede extraerse correctamente mediante OCR, se procesa con Groq (`llama-3.1-8b-instant`), un modelo más rápido y liviano para estructurar la información. Cuando el documento requiere interpretación visual directa o el OCR no es suficiente, se utiliza Gemini. De esta forma se optimizan las cuotas disponibles y el usuario cuenta con más de una alternativa de procesamiento.

Antes de extraer los datos, el documento se clasifica para verificar que corresponda a una compra. Si es válido, se obtienen campos como comercio, RUT, número de documento, fecha, total, IVA y productos. Finalmente, la información pasa por un formulario editable para que el usuario pueda revisarla y corregirla antes de guardarla.

## Prompt de IA

El prompt principal está ubicado en:

```txt
config/prompts/receipt_extraction.txt
```

Resumen de las instrucciones usadas:

El prompt obliga al modelo a responder sólo JSON válido. Primero clasifica el documento (`document_type`, `is_purchase_receipt`, `confidence`) y sólo extrae datos si corresponde a una compra o voucher válido. Si el documento no es una compra, devuelve los campos en `null` y explica brevemente el motivo.

También se instruye al modelo a no inventar información, usar `null` cuando un dato no sea confiable, distinguir líneas de resumen como IVA/total/subtotal de productos reales, y elegir la fecha o número de documento según el tipo de comprobante.

Ejemplo breve de salida esperada:

```json
{
  "document_type": "receipt",
  "is_purchase_receipt": true,
  "confidence": 0.96,
  "rejection_reason": null,
  "merchant_name": "SUPERMERCADO EJEMPLO SPA",
  "merchant_rut": "76123456-7",
  "document_number": "123456",
  "purchase_date": "2026-07-06",
  "total_amount": 8990,
  "tax_amount": 1435,
  "items": [
    {
      "description": "Pan integral",
      "quantity": 1,
      "unit_price": 1990,
      "discount_amount": 0,
      "total_price": 1990
    }
  ]
}
```

Ejemplo de documento rechazado:

```json
{
  "document_type": "bank_transfer",
  "is_purchase_receipt": false,
  "confidence": 0.98,
  "rejection_reason": "El documento parece corresponder a un comprobante de transferencia bancaria.",
  "merchant_name": null,
  "merchant_rut": null,
  "document_number": null,
  "purchase_date": null,
  "total_amount": null,
  "tax_amount": null,
  "items": []
}
```

## Mejoras Futuras

Si tuviera más tiempo, me gustaría llevar la aplicación más allá del almacenamiento de compras y enfocarla también en análisis. Como los datos quedan estructurados en campos como comercio, fecha, total, IVA e ítems, la base queda preparada para construir reportes de gastos, análisis por comercio, filtros por período y exportaciones.

También incorporaría gestión de usuarios para que cada persona o empresa pueda administrar sus propias compras de forma separada y segura. Esto permitiría potenciar el uso real de la aplicación, no sólo como procesador de boletas, sino como una herramienta de consulta y seguimiento.

A nivel técnico, una mejora importante sería mover el procesamiento de OCR e IA a trabajos en segundo plano, especialmente para archivos pesados o cuando los proveedores tengan límites temporales. Además, guardaría el documento original con Active Storage para permitir auditoría, descarga y reprocesamiento futuro.

## Capturas

<table>
  <tr>
    <td width="70%">
      <img src="app/assets/images/1.png" alt="Carga de boleta en escritorio">
    </td>
    <td width="30%">
      <img src="app/assets/images/1mobile.png" alt="Carga de boleta en móvil">
    </td>
  </tr>
  <tr>
    <td width="70%">
      <img src="app/assets/images/3.png" alt="Revisión de datos en escritorio">
    </td>
    <td width="30%">
      <img src="app/assets/images/3mobile.png" alt="Revisión de datos en móvil">
    </td>
  </tr>
</table>

<img src="app/assets/images/2.png" alt="Listado de compras">

<img src="app/assets/images/4.png" alt="Detalle de compra">
