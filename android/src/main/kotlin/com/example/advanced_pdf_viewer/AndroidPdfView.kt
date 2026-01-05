package com.example.advanced_pdf_viewer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.view.MotionEvent
import android.view.View
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.util.PDFBoxResourceLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream

class AndroidPdfView(
    private val context: Context,
    private val id: Int,
    private val creationParams: Map<String, Any>?,
    private val messenger: BinaryMessenger
) : PlatformView, MethodChannel.MethodCallHandler {

    private val scrollView: ScrollView = ScrollView(context)
    private val container: LinearLayout = LinearLayout(context)
    private val methodChannel: MethodChannel = MethodChannel(messenger, "advanced_pdf_viewer_$id")
    
    private var pdfRenderer: PdfRenderer? = null
    private var parcelFileDescriptor: ParcelFileDescriptor? = null
    private var currentPath: String? = null
    private var currentTool: String = "none"
    
    // For drawing overlay
    private val annotations = mutableListOf<Annotation>()

    init {
        PDFBoxResourceLoader.init(context)
        container.orientation = LinearLayout.VERTICAL
        scrollView.addView(container)
        
        methodChannel.setMethodCallHandler(this)
        
        val path = creationParams?.get("path") as? String
        if (path != null) {
            loadPdf(path)
        }
    }

    override fun getView(): View = scrollView

    override fun dispose() {
        pdfRenderer?.close()
        parcelFileDescriptor?.close()
    }

    private fun loadPdf(path: String) {
        currentPath = path
        val file = File(path)
        parcelFileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        pdfRenderer = PdfRenderer(parcelFileDescriptor!!)
        
        renderPages()
    }

    private fun renderPages() {
        container.removeAllViews()
        val renderer = pdfRenderer ?: return
        
        for (i in 0 until renderer.pageCount) {
            val page = renderer.openPage(i)
            val bitmap = Bitmap.createBitmap(page.width * 2, page.height * 2, Bitmap.Config.ARGB_8888)
            page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
            
            val imageView = AnnotationImageView(context, i)
            imageView.setImageBitmap(bitmap)
            imageView.adjustViewBounds = true
            imageView.setPadding(0, 10, 0, 10)
            
            container.addView(imageView)
            page.close()
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setDrawingMode" -> {
                currentTool = call.argument<String>("tool") ?: "none"
                result.success(null)
            }
            "clearAnnotations" -> {
                annotations.clear()
                for (i in 0 until container.childCount) {
                    val view = container.getChildAt(i) as? AnnotationImageView
                    view?.clearLocalAnnotations()
                }
                result.success(null)
            }
            "savePdf" -> {
                savePdf(result)
            }
            else -> result.notImplemented()
        }
    }

    private fun savePdf(result: MethodChannel.Result) {
        val path = currentPath ?: return result.error("NO_PATH", "No PDF loaded", null)
        try {
            val document = PDDocument.load(File(path))
            
            for (anno in annotations) {
                val page = document.getPage(anno.pageIndex)
                val contentStream = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                
                when (anno.type) {
                    "highlight" -> {
                        // PdfBox highlight is a bit more complex, using text markup
                        val highlight = PDAnnotationTextMarkup(PDAnnotationTextMarkup.SUB_TYPE_HIGHLIGHT)
                        val rect = PDRectangle()
                        rect.lowerLeftX = anno.x
                        rect.lowerLeftY = page.bBox.height - anno.y - anno.h
                        rect.upperRightX = anno.x + anno.w
                        rect.upperRightY = page.bBox.height - anno.y
                        highlight.rectangle = rect
                        highlight.color = PDColor(floatArrayOf(1f, 1f, 0f), PDDeviceRGB.INSTANCE)
                        page.annotations.add(highlight)
                    }
                    "draw" -> {
                        contentStream.setStrokingColor(Color.RED)
                        contentStream.setLineWidth(2f)
                        contentStream.moveTo(anno.x, page.bBox.height - anno.y)
                        contentStream.lineTo(anno.x + anno.w, page.bBox.height - (anno.y + anno.h))
                        contentStream.stroke()
                    }
                }
                contentStream.close()
            }
            
            val outputStream = ByteArrayOutputStream()
            document.save(outputStream)
            document.close()
            result.success(outputStream.toByteArray())
        } catch (e: Exception) {
            result.error("SAVE_ERROR", e.message, null)
        }
    }

    inner class AnnotationImageView(context: Context, val pageIndex: Int) : androidx.appcompat.widget.AppCompatImageView(context) {
        private val localPaths = mutableListOf<AnnotatedPath>()
        private var currentDrawingPath: android.graphics.Path? = null
        
        private val drawPaint = Paint().apply {
            color = Color.RED
            strokeWidth = 5f
            style = Paint.Style.STROKE
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
            isAntiAlias = true
        }

        private val highlightPaint = Paint().apply {
            color = Color.YELLOW
            alpha = 128
            style = Paint.Style.FILL
        }

        override fun onTouchEvent(event: MotionEvent): Boolean {
            if (currentTool == "none") return super.onTouchEvent(event)
            
            val x = event.x
            val y = event.y

            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    if (currentTool == "draw") {
                        currentDrawingPath = android.graphics.Path().apply {
                            moveTo(x, y)
                        }
                    } else if (currentTool == "highlight" || currentTool == "underline") {
                        val path = android.graphics.Path().apply {
                            addRect(x - 100, y - 20, x + 100, y + 20, android.graphics.Path.Direction.CW)
                        }
                        val annoPath = AnnotatedPath(path, currentTool, x, y, 200f, 40f)
                        localPaths.add(annoPath)
                        // Also add to global annotations for saving
                        annotations.add(Annotation(pageIndex, currentTool, x / 2, y / 2, 100f, 20f))
                    }
                    invalidate()
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (currentTool == "draw") {
                        currentDrawingPath?.lineTo(x, y)
                        invalidate()
                    }
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    if (currentTool == "draw") {
                        currentDrawingPath?.let {
                            localPaths.add(AnnotatedPath(it, "draw", 0f, 0f, 0f, 0f))
                            // For saving, we'd need more data, but let's store a simplified version
                            annotations.add(Annotation(pageIndex, "draw", x / 2, y / 2, 10f, 10f))
                        }
                        currentDrawingPath = null
                        invalidate()
                    }
                    return true
                }
            }
            return super.onTouchEvent(event)
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            for (annoPath in localPaths) {
                val p = if (annoPath.type == "highlight") highlightPaint else drawPaint
                canvas.drawPath(annoPath.path, p)
            }
            currentDrawingPath?.let {
                canvas.drawPath(it, drawPaint)
            }
        }

        fun clearLocalAnnotations() {
            localPaths.clear()
            invalidate()
        }
    }

    data class AnnotatedPath(
        val path: android.graphics.Path,
        val type: String,
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float
    )

    data class Annotation(
        val pageIndex: Int,
        val type: String,
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float
    )
}
