package com.example.advanced_pdf_viewer

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.RectF
import android.graphics.pdf.PdfRenderer
import android.os.ParcelFileDescriptor
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.GestureDetector
import android.view.ScaleGestureDetector
import android.view.View
import android.view.ViewGroup
import android.view.Gravity
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.Stack
import java.text.Bidi
import java.util.concurrent.Executors

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.common.PDRectangle
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDColor
import com.tom_roush.pdfbox.pdmodel.graphics.color.PDDeviceRGB
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.text.PDFTextStripperByArea
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.pdmodel.graphics.blend.BlendMode

import com.tom_roush.pdfbox.io.MemoryUsageSetting

class AndroidPdfView(
    private val context: Context,
    private val id: Int,
    private val creationParams: Map<String, Any>?,
    private val messenger: BinaryMessenger
) : PlatformView, MethodChannel.MethodCallHandler {

    private class LockableLinearLayoutManager(context: Context) : LinearLayoutManager(context) {
        var scrollable = true
        override fun canScrollVertically(): Boolean = scrollable && super.canScrollVertically()
    }

    private val recyclerView = RecyclerView(context)
    private val layoutManager = LockableLinearLayoutManager(context)
    private val methodChannel: MethodChannel = MethodChannel(messenger, "advanced_pdf_viewer_$id")
    
    private val pdfRendererLock = Any() // Lock for PdfRenderer synchronization
    private val pdfBoxLock = Any() // Lock for PDFBox interactionDocument
    private var pdfRenderer: PdfRenderer? = null
    private var parcelFileDescriptor: ParcelFileDescriptor? = null
    
    // Cached PDDocument for interactions (snapping) to prevent repeated loading/OOM
    // This is opened in loadPdf and closed in dispose
    private var interactionDocument: PDDocument? = null 
    
    private var currentPath: String? = null
    private var currentTool: String = "none"
    private var isTempFile: Boolean = false
    
    // Reduced thread pool size to prevent OOM on lower end devices
    private val renderExecutor = Executors.newFixedThreadPool(2)
    // Single thread for interactions to prevent race conditions and parallel heavy loads
    private val interactionExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    
    private var drawColor: Int = Color.RED
    private var highlightColor: Int = Color.YELLOW
    private var underlineColor: Int = Color.BLUE
    private var enablePageNumber: Boolean = false
    
    private val undoStack = Stack<Annotation>()
    private val redoStack = Stack<Annotation>()
    
    private var currentScale: Float = 1.0f
    private var translateX: Float = 0f
    private var translateY: Float = 0f
    private val minScale: Float = 1.0f
    private val maxScale: Float = 5.0f

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val scaleFactor = detector.scaleFactor
            val prevScale = currentScale
            currentScale *= scaleFactor
            currentScale = Math.max(minScale, Math.min(currentScale, maxScale))
            
            val focalX = detector.focusX
            val focalY = detector.focusY
            translateX -= (focalX / prevScale - focalX / currentScale) * currentScale
            translateY -= (focalY / prevScale - focalY / currentScale) * currentScale
            
            updateZoom()
            return true
        }
    })

    private val panGestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
        override fun onScroll(e1: MotionEvent?, e2: MotionEvent, distanceX: Float, distanceY: Float): Boolean {
            if (currentScale > 1.0f && currentTool == "none") {
                translateX -= distanceX
                translateY -= distanceY
                updateZoom()
                return true
            }
            return false
        }
    })
    
    private val bitmapCache = object : android.util.LruCache<Int, Bitmap>((Runtime.getRuntime().maxMemory() / 8).toInt()) {
        override fun sizeOf(key: Int, value: Bitmap): Int = value.byteCount
    }

    init {
        try {
            PDFBoxResourceLoader.init(context)
        } catch (e: Throwable) {
            System.err.println("PDF View Critical Error initializing PDFBox: ${e.message}")
            e.printStackTrace()
        }
        
        recyclerView.layoutManager = layoutManager
        recyclerView.adapter = PdfAdapter()
        recyclerView.setItemViewCacheSize(3) // Reduced cache size
        recyclerView.setHasFixedSize(true)
        
        recyclerView.setOnTouchListener { _, event ->
            scaleDetector.onTouchEvent(event)
            if (scaleDetector.isInProgress) return@setOnTouchListener true

            if (currentScale > 1.0f) {
                panGestureDetector.onTouchEvent(event)
                return@setOnTouchListener true
            }
            false
        }
        
        methodChannel.setMethodCallHandler(this)
        val path = creationParams?.get("path") as? String
        isTempFile = creationParams?.get("isTempFile") as? Boolean ?: false
        
        if (path != null) {
            loadPdf(path)
        }
    }

    override fun getView(): android.view.View = recyclerView

    override fun dispose() {
        pdfRenderer?.close()
        parcelFileDescriptor?.close()
        
        // Close interaction document
        interactionExecutor.execute {
            try {
                interactionDocument?.close()
                interactionDocument = null
            } catch (e: Exception) {}
        }
        interactionExecutor.shutdown()
        
        bitmapCache.evictAll()
        renderExecutor.shutdown()
    }

    private fun loadPdf(path: String) {
        currentPath = path
        val file = File(path)
        
        if (!file.exists() || file.length() == 0L) {
            System.err.println("PDF View Error: File does not exist or is empty: $path")
            return
        }

        try {
            // REMOVED file.delete() to prevent issues with ParcelFileDescriptor on some devices/OS versions
            
            parcelFileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            pdfRenderer = PdfRenderer(parcelFileDescriptor!!)
            recyclerView.adapter?.notifyDataSetChanged()
            
            // Initialize the interaction document in background
            interactionExecutor.execute {
                try {
                     synchronized(pdfBoxLock) {
                        if (interactionDocument != null) {
                            try { interactionDocument?.close() } catch(e: Exception){}
                        }
                        interactionDocument = PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
                     }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        } catch (e: Throwable) {
            // Catch RuntimeException, SecurityException, and IOException
            System.err.println("PDF View Critical Error initializing PdfRenderer: ${e.message}")
            e.printStackTrace()
        }
    }

    inner class PdfAdapter : RecyclerView.Adapter<PdfViewHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PdfViewHolder {
            val container = LinearLayout(context)
            container.orientation = LinearLayout.VERTICAL
            container.layoutParams = RecyclerView.LayoutParams(
                RecyclerView.LayoutParams.MATCH_PARENT,
                RecyclerView.LayoutParams.WRAP_CONTENT
            )
            container.gravity = Gravity.CENTER_HORIZONTAL

            val pdfView = AnnotationImageView(context, 0, 1, 1)
            pdfView.layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            pdfView.adjustViewBounds = true
            
            val pageNumView = TextView(context)
            pageNumView.layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT,
                LinearLayout.LayoutParams.WRAP_CONTENT
            )
            pageNumView.gravity = Gravity.CENTER
            pageNumView.setTextColor(Color.BLACK)
            pageNumView.textSize = 12f
            pageNumView.setPadding(0, 8, 0, 16)
            
            container.addView(pdfView)
            container.addView(pageNumView)
            
            return PdfViewHolder(container)
        }

        override fun onBindViewHolder(holder: PdfViewHolder, position: Int) {
            val renderer = pdfRenderer ?: return
            if (position < 0 || position >= renderer.pageCount) return
            
            val container = holder.itemView as LinearLayout
            val imageView = container.getChildAt(0) as AnnotationImageView
            val pageNumView = container.getChildAt(1) as TextView
            
            pageNumView.text = "${position + 1}"
            pageNumView.visibility = if (enablePageNumber) View.VISIBLE else View.GONE
            
            var w = 0
            var h = 0
            try {
                synchronized(pdfRendererLock) {
                    val page = renderer.openPage(position)
                    w = page.width
                    h = page.height
                    page.close()
                }
            } catch (e: Exception) {
                return
            }
            
            imageView.updatePageInfo(position, w, h)
            
            val cached = bitmapCache.get(position)
            if (cached != null) {
                imageView.setImageBitmap(cached)
            } else {
                imageView.setImageBitmap(null)
                renderExecutor.execute {
                    try {
                        val renderer = pdfRenderer ?: return@execute
                        // Double check renderer still exists/open
                        
                        // Synchronize on lock to ensure no parallel page access
                        synchronized(pdfRendererLock) {
                            val page = renderer.openPage(position)
                            
                            // Use ARGB_8888 as RGB_565 is not supported by PdfRenderer
                            // Maintain 1.5x scale to keep memory usage lower than original 2.0x
                            var bitmap: Bitmap? = null
                            try {
                                 val scale = 1.5f
                                 bitmap = Bitmap.createBitmap((w * scale).toInt(), (h * scale).toInt(), Bitmap.Config.ARGB_8888)
                                 page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            } catch (e: OutOfMemoryError) {
                                // Fallback to 1.0 scale if still OOM
                                try {
                                    val scale = 1.0f
                                    bitmap = Bitmap.createBitmap((w * scale).toInt(), (h * scale).toInt(), Bitmap.Config.ARGB_8888)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                } catch (e2: OutOfMemoryError) {
                                    // Failed to allocate even low res
                                    e2.printStackTrace()
                                }
                            }
                            
                            page.close()
                            
                            if (bitmap != null) {
                                bitmapCache.put(position, bitmap)
                                mainHandler.post {
                                    if (imageView.pageIndex == position) {
                                        imageView.setImageBitmap(bitmap)
                                    }
                                }
                            }
                        }
                    } catch (e: Exception) {
                        e.printStackTrace()
                    }
                }
            }
        }

        override fun getItemCount(): Int = pdfRenderer?.pageCount ?: 0
    }

    class PdfViewHolder(view: View) : RecyclerView.ViewHolder(view)

    private fun getIntArg(call: MethodCall, key: String): Int? {
        return (call.argument<Any>(key) as? Number)?.toInt()
    }

    private fun getDoubleArg(call: MethodCall, key: String): Double? {
        return (call.argument<Any>(key) as? Number)?.toDouble()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setDrawingMode" -> {
                currentTool = call.argument<String>("tool") ?: "none"
                layoutManager.scrollable = currentTool == "none"
                result.success(null)
            }
            "setScrollLocked" -> {
                val locked = call.argument<Boolean>("locked") ?: false
                layoutManager.scrollable = !locked
                result.success(null)
            }
            "clearAnnotations" -> {
                undoStack.clear()
                redoStack.clear()
                refreshAllViews()
                result.success(null)
            }
            "undo" -> {
                if (undoStack.isNotEmpty()) {
                    redoStack.push(undoStack.pop())
                    refreshAllViews()
                }
                result.success(null)
            }
            "redo" -> {
                if (redoStack.isNotEmpty()) {
                    undoStack.push(redoStack.pop())
                    refreshAllViews()
                }
                result.success(null)
            }
            "savePdf" -> {
                savePdf(result)
            }
            "addTextAnnotation" -> {
                val text = call.argument<String>("text")
                val x = getDoubleArg(call, "x")?.toFloat() ?: 0f
                val y = getDoubleArg(call, "y")?.toFloat() ?: 0f
                val pageIndex = getIntArg(call, "pageIndex") ?: 0
                val colorInt = getIntArg(call, "color")
                
                if (text != null) {
                    val color = colorInt ?: Color.BLACK
                    val anno = Annotation(pageIndex, "text", x, y, 200f, 50f, text, color)
                    addAnnotation(anno)
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENTS", "Text is required", null)
                }
            }
            "jumpToPage" -> {
                val pageIndex = getIntArg(call, "page") ?: 0
                (layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(pageIndex, 0)
                result.success(null)
            }
            "getTotalPages" -> {
                result.success(pdfRenderer?.pageCount ?: 0)
            }
            "updateConfig" -> {
                getIntArg(call, "drawColor")?.let { drawColor = it }
                getIntArg(call, "highlightColor")?.let { highlightColor = it }
                getIntArg(call, "underlineColor")?.let { underlineColor = it }
                call.argument<Boolean>("enablePageNumber")?.let { 
                    enablePageNumber = it 
                    refreshAllViews()
                }
                result.success(null)
            }
            "zoomIn" -> {
                val prevScale = currentScale
                currentScale = Math.min(currentScale + 0.5f, maxScale)
                updateZoom()
                result.success(null)
            }
            "zoomOut" -> {
                val prevScale = currentScale
                currentScale = Math.max(currentScale - 0.5f, minScale)
                if (currentScale == 1.0f) {
                    translateX = 0f
                    translateY = 0f
                }
                updateZoom()
                result.success(null)
            }
            "setZoom" -> {
                val scale = getDoubleArg(call, "scale")?.toFloat() ?: 1.0f
                currentScale = Math.max(minScale, Math.min(scale, maxScale))
                if (currentScale == 1.0f) {
                    translateX = 0f
                    translateY = 0f
                }
                updateZoom()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun updateZoom() {
        val maxTx = 0f
        val maxTy = 0f
        val minTx = -(recyclerView.width * currentScale - recyclerView.width)
        val minTy = -(recyclerView.height * currentScale - recyclerView.height)
        
        if (currentScale > 1.0f) {
            translateX = Math.max(minTx, Math.min(translateX, maxTx))
            translateY = Math.max(minTy, Math.min(translateY, maxTy))
        } else {
            translateX = 0f
            translateY = 0f
        }

        recyclerView.scaleX = currentScale
        recyclerView.scaleY = currentScale
        recyclerView.translationX = translateX
        recyclerView.translationY = translateY
        recyclerView.pivotX = 0f
        recyclerView.pivotY = 0f
    }

    private fun addAnnotation(anno: Annotation) {
        undoStack.push(anno)
        redoStack.clear()
        refreshAllViews()
    }

    private fun refreshAllViews() {
        recyclerView.adapter?.notifyDataSetChanged()
    }

    private fun setPdfBoxColor(contentStream: PDPageContentStream, color: Int, isNonStroking: Boolean) {
        val r = (color shr 16) and 0xFF
        val g = (color shr 8) and 0xFF
        val b = color and 0xFF
        if (isNonStroking) {
            contentStream.setNonStrokingColor(r, g, b)
        } else {
            contentStream.setStrokingColor(r, g, b)
        }
    }

    private fun drawMixedText(
        contentStream: PDPageContentStream,
        text: String,
        x: Float,
        y: Float,
        pageHeight: Float,
        arabicFont: PDFont,
        latinFont: PDFont,
        fontSize: Float,
        color: Int
    ) {
        try {
            contentStream.beginText()
            setPdfBoxColor(contentStream, color, true)
            contentStream.newLineAtOffset(x, pageHeight - y)
            
            var currentText = StringBuilder()
            var currentIsArabic: Boolean? = null
            
            for (c in text) {
                val charIsArabic = ArabicShaper.isArabic(c)
                if (currentIsArabic == null) {
                    currentIsArabic = charIsArabic
                    currentText.append(c)
                } else if (charIsArabic == currentIsArabic) {
                    currentText.append(c)
                } else {
                    contentStream.setFont(if (currentIsArabic!!) arabicFont else latinFont, fontSize)
                    try {
                        contentStream.showText(currentText.toString())
                    } catch (e: Exception) {
                        contentStream.setFont(if (currentIsArabic!!) latinFont else arabicFont, fontSize)
                        contentStream.showText(currentText.toString())
                    }
                    currentText = StringBuilder().append(c)
                    currentIsArabic = charIsArabic
                }
            }
            
            if (currentText.isNotEmpty()) {
                contentStream.setFont(if (currentIsArabic!!) arabicFont else latinFont, fontSize)
                try {
                    contentStream.showText(currentText.toString())
                } catch (e: Exception) {
                    contentStream.setFont(if (currentIsArabic!!) latinFont else arabicFont, fontSize)
                    contentStream.showText(currentText.toString())
                }
            }
            
            contentStream.endText()
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            contentStream.close()
        }
    }

    private fun savePdf(result: MethodChannel.Result) {
        val path = currentPath ?: return result.error("NO_PATH", "No PDF loaded", null)
        
        interactionExecutor.execute {
            var tempFile: File? = null

            try {
                // 1. FREE MEMORY: Close interaction document and clear caches
                synchronized(pdfBoxLock) {
                    try {
                        interactionDocument?.close()
                        interactionDocument = null
                    } catch (e: Exception) {}
                }
                
                runCatching {
                    bitmapCache.evictAll()
                    System.gc()
                    Thread.sleep(100) 
                }

                // 2. LOAD & SAVE: Load fresh document purely for saving
                // Use temp file for buffering instead of RAM
                val document = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                
                try {
                    // Font loading logic
                    var font: PDFont? = null
                    try {
                        val inputStream: InputStream = context.assets.open("flutter_assets/assets/fonts/Arial.ttf")
                        font = PDType0Font.load(document, inputStream)
                    } catch (e: Exception) {}
                    
                    if (font == null) {
                        val fontPaths = arrayOf(
                            "/system/fonts/Arial.ttf",
                            "/system/fonts/NotoSansArabic-Regular.ttf",
                            "/system/fonts/NotoNaskhArabic-Regular.ttf",
                            "/system/fonts/DroidSansArabic.ttf"
                        )
                        for (fp in fontPaths) {
                            val f = File(fp)
                            if (f.exists()) {
                                try {
                                    font = PDType0Font.load(document, f)
                                    break
                                } catch (e: Exception) {}
                            }
                        }
                    }
                    if (font == null) {
                        font = com.tom_roush.pdfbox.pdmodel.font.PDType1Font.HELVETICA_BOLD
                    }
                
                    // Apply annotations
                    val stackCopy = ArrayList(undoStack)
                    for (anno in stackCopy) {
                        val page = document.getPage(anno.pageIndex)
                        val pageHeight = page.bBox.height
                        
                        val x = anno.x
                        val y = anno.y
                        val w = anno.w
                        val h = anno.h
                        
                        when (anno.type) {
                            "highlight" -> {
                                val contentStream = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                val gState = PDExtendedGraphicsState()
                                gState.nonStrokingAlphaConstant = 0.5f 
                                gState.blendMode = BlendMode.MULTIPLY
                                contentStream.setGraphicsStateParameters(gState)
                                setPdfBoxColor(contentStream, anno.color, true)
                                val pdfY = pageHeight - y - h
                                contentStream.addRect(x, pdfY, w, h)
                                contentStream.fill()
                                contentStream.close()
                            }
                            "underline" -> {
                                val contentStream = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                setPdfBoxColor(contentStream, anno.color, false)
                                contentStream.setLineWidth(1.5f)
                                val pdfY = pageHeight - y - h
                                contentStream.moveTo(x, pdfY)
                                contentStream.lineTo(x + w, pdfY)
                                contentStream.stroke()
                                contentStream.close()
                            }
                            "text" -> {
                                val shapedText = ArabicShaper.shape(anno.text ?: "")
                                val latinFont = com.tom_roush.pdfbox.pdmodel.font.PDType1Font.HELVETICA_BOLD
                                drawMixedText(
                                    contentStream = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true),
                                    text = shapedText,
                                    x = x,
                                    y = y,
                                    pageHeight = pageHeight,
                                    arabicFont = font!!,
                                    latinFont = latinFont,
                                    fontSize = 14f,
                                    color = anno.color
                                )
                            }
                            "draw" -> {
                                val points = anno.points ?: continue
                                if (points.isNotEmpty()) {
                                    val contentStream = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                    setPdfBoxColor(contentStream, drawColor, false)
                                    contentStream.setLineWidth(2f)
                                    contentStream.moveTo(points[0].x, pageHeight - points[0].y)
                                    for (i in 1 until points.size) {
                                        contentStream.lineTo(points[i].x, pageHeight - points[i].y)
                                    }
                                    contentStream.stroke()
                                    contentStream.close()
                                }
                            }
                        }
                    }
                    
                    // Save to temp file
                    tempFile = File.createTempFile("saved_pdf_", ".pdf", context.cacheDir)
                    document.save(tempFile)
                } finally {
                    document.close() // Close save document explicitly
                }

                // 3. READ BYTES (Potentially risky but required by API)
                val bytes = tempFile.readBytes()
                
                // 4. RESTORE: Re-open interaction document
                synchronized(pdfBoxLock) {
                    interactionDocument = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                }
                
                Handler(Looper.getMainLooper()).post {
                    result.success(bytes)
                }
            } catch (e: Exception) {
                e.printStackTrace()
                // Minimize damage if crash, try to re-open interaction doc
                try {
                     synchronized(pdfBoxLock) {
                        if (interactionDocument == null) {
                             interactionDocument = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                        }
                     }
                } catch(ign: Exception) {}
                
                Handler(Looper.getMainLooper()).post {
                    result.error("SAVE_ERROR", e.message, null)
                }
            } finally {
                 tempFile?.delete()
            }
        }
    }

    inner class AnnotationImageView(context: Context, var pageIndex: Int, var pdfWidth: Int, var pdfHeight: Int) : ImageView(context) {
        
        fun updatePageInfo(index: Int, width: Int, height: Int) {
            this.pageIndex = index
            this.pdfWidth = width
            this.pdfHeight = height
            invalidate()
        }
        private var currentDrawingPath: Path? = null
        private var currentDrawingPoints = mutableListOf<PointF>()
        
        private var selectionStartPoint = PointF()
        private var selectionEndPoint = PointF()
        private var isSelecting = false
        
        private val drawPaint = Paint().apply {
            strokeWidth = 5f
            style = Paint.Style.STROKE
            strokeJoin = Paint.Join.ROUND
            strokeCap = Paint.Cap.ROUND
            isAntiAlias = true
        }

        private fun getScale(): Float {
            if (width == 0) return 1f
            return pdfWidth.toFloat() / width.toFloat()
        }

        private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                val scale = getScale()
                val x = e.x * scale
                val y = e.y * scale
                
                if (currentTool == "text") {
                    methodChannel.invokeMethod("onPdfTapped", mapOf(
                        "x" to x, 
                        "y" to y,
                        "pageIndex" to pageIndex
                    ))
                    return true
                } else if (currentTool == "highlight" || currentTool == "underline") {
                    snapToText(x, y)
                    return true
                }
                return false
            }
        })

        private fun snapToText(x: Float, y: Float) {
            interactionExecutor.execute {
                val document = interactionDocument ?: return@execute
                try {
                    synchronized(pdfBoxLock) {
                        val locator = TextLocator(pageIndex, x, y)
                        locator.getTextPositions(document)
                        
                        val bounds = locator.bestMatch
                        post {
                            if (bounds != null) {
                                val h = if (currentTool == "highlight") bounds.height() else 8f
                                // REMOVED EXTRA PADDING HERE to allow cleaner reversion
                                val yOffset = if (currentTool == "highlight") 0f else bounds.height() - 2f
                                
                                val anno = Annotation(
                                    pageIndex, currentTool, 
                                    bounds.left, bounds.top + yOffset, 
                                    bounds.width(), if (currentTool == "highlight") h else 4f, 
                                    null, 
                                    if (currentTool == "highlight") highlightColor else underlineColor
                                )
                                addAnnotation(anno)
                            } else {
                                val h = if (currentTool == "highlight") 30f else 6f
                                val anno = Annotation(
                                    pageIndex, currentTool, 
                                    x - 100, y - h/4, 
                                    200f, h/2, null, 
                                    if (currentTool == "highlight") highlightColor else underlineColor
                                )
                                addAnnotation(anno)
                            }
                        }
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }

        private fun snapToTextRange(x1: Float, y1: Float, x2: Float, y2: Float) {
             interactionExecutor.execute {
                val document = interactionDocument ?: return@execute
                try {
                    synchronized(pdfBoxLock) {
                        val locator = TextRangeLocator(pageIndex, x1, y1, x2, y2)
                        locator.getTextPositions(document)
                        
                        val matches = locator.lineMatches
                        post {
                            if (matches.isNotEmpty()) {
                                for (bounds in matches) {
                                    val h = if (currentTool == "highlight") bounds.height() else 8f
                                    val yOffset = if (currentTool == "highlight") 0f else bounds.height() - 2f
                                    
                                    val anno = Annotation(
                                        pageIndex, currentTool, 
                                        bounds.left, bounds.top + yOffset, 
                                        bounds.width(), if (currentTool == "highlight") bounds.height() else 4f, 
                                        null, 
                                        if (currentTool == "highlight") highlightColor else underlineColor
                                    )
                                    addAnnotation(anno)
                                }
                            } else {
                                // Fallback to manual box
                                val left = Math.min(x1, x2)
                                val top = Math.min(y1, y2)
                                val right = Math.max(x1, x2)
                                val bottom = Math.max(y1, y2)
                                val w = Math.max(right - left, 50f)
                                val h = if (currentTool == "highlight") Math.max(bottom - top, 20f) else 6f
                                
                                val anno = Annotation(
                                    pageIndex, currentTool, 
                                    left, top, 
                                    w, h, null, 
                                    if (currentTool == "highlight") highlightColor else underlineColor
                                )
                                addAnnotation(anno)
                            }
                        }
                    }
                } catch (e: Exception) {
                    e.printStackTrace()
                }
            }
        }

        override fun onTouchEvent(event: MotionEvent?): Boolean {
            if (event != null && gestureDetector.onTouchEvent(event)) return true
            if (currentTool == "none") return super.onTouchEvent(event)
            
            val scale = getScale()
            val x = event?.x ?: 0f
            val y = event?.y ?: 0f

            when (event?.action) {
                MotionEvent.ACTION_DOWN -> {
                    if (currentTool == "draw") {
                        currentDrawingPath = Path().apply { moveTo(x, y) }
                        currentDrawingPoints.clear()
                        currentDrawingPoints.add(PointF(x * scale, y * scale))
                    } else if (currentTool == "highlight" || currentTool == "underline") {
                        selectionStartPoint.set(x * scale, y * scale)
                        selectionEndPoint.set(x * scale, y * scale)
                        isSelecting = true
                    }
                    invalidate()
                    return true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (currentTool == "draw") {
                        currentDrawingPath?.lineTo(x, y)
                        currentDrawingPoints.add(PointF(x * scale, y * scale))
                    } else if (isSelecting) {
                        selectionEndPoint.set(x * scale, y * scale)
                    }
                    invalidate()
                    return true
                }
                MotionEvent.ACTION_UP -> {
                    if (currentTool == "draw") {
                        if (currentDrawingPoints.isNotEmpty()) {
                            addAnnotation(Annotation(
                                pageIndex, "draw", 0f, 0f, 0f, 0f, null, drawColor,
                                ArrayList(currentDrawingPoints)
                            ))
                        }
                        currentDrawingPath = null
                        currentDrawingPoints.clear()
                    } else if (isSelecting) {
                        isSelecting = false
                        snapToTextRange(selectionStartPoint.x, selectionStartPoint.y, selectionEndPoint.x, selectionEndPoint.y)
                    }
                    invalidate()
                    return true
                }
            }
            return true
        }

        fun refreshAnnotations() {
            invalidate()
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            
            val scale = getScale()
            if (scale == 0f) return
            val invScale = 1f / scale
            
            for (anno in undoStack) {
                if (anno.pageIndex != pageIndex) continue
                
                when (anno.type) {
                    "text" -> {
                        val textPaint = Paint().apply {
                            color = anno.color
                            textSize = 34f * invScale / 2f 
                            isFakeBoldText = true
                        }
                        textPaint.textSize = 14f * invScale
                        canvas.drawText(anno.text ?: "", anno.x * invScale, anno.y * invScale, textPaint)
                    }
                    "highlight" -> {
                        val p = Paint().apply { 
                            color = anno.color
                            alpha = 100 // Visual only, semi-transparent
                            style = Paint.Style.FILL
                        }
                        canvas.drawRect(anno.x * invScale, anno.y * invScale, (anno.x + anno.w) * invScale, (anno.y + anno.h) * invScale, p)
                    }
                    "underline" -> {
                        val p = Paint().apply { 
                            color = anno.color
                            strokeWidth = 2f * invScale
                            style = Paint.Style.STROKE
                        }
                        canvas.drawLine(anno.x * invScale, (anno.y + anno.h) * invScale, (anno.x + anno.w) * invScale, (anno.y + anno.h) * invScale, p)
                    }
                    "draw" -> {
                        val points = anno.points ?: continue
                        if (points.size < 2) continue
                        val p = Paint(drawPaint).apply { 
                            color = anno.color
                            strokeWidth = 2f * invScale
                        }
                        val path = Path()
                        path.moveTo(points[0].x * invScale, points[0].y * invScale)
                        for (i in 1 until points.size) {
                            path.lineTo(points[i].x * invScale, points[i].y * invScale)
                        }
                        canvas.drawPath(path, p)
                    }
                }
            }
            
            currentDrawingPath?.let {
                drawPaint.color = drawColor
                drawPaint.strokeWidth = 5f
                canvas.drawPath(it, drawPaint)
            }

            if (isSelecting) {
                val p = Paint().apply {
                    color = if (currentTool == "highlight") highlightColor else underlineColor
                    alpha = 128
                    style = Paint.Style.FILL
                }
                val invScale = 1f / scale
                val left = Math.min(selectionStartPoint.x, selectionEndPoint.x) * invScale
                val top = Math.min(selectionStartPoint.y, selectionEndPoint.y) * invScale
                val right = Math.max(selectionStartPoint.x, selectionEndPoint.x) * invScale
                val bottom = Math.max(selectionStartPoint.y, selectionEndPoint.y) * invScale
                canvas.drawRect(left, top, right, bottom, p)
            }
        }
    }

    data class Annotation(
        val pageIndex: Int,
        val type: String,
        val x: Float,
        val y: Float,
        val w: Float,
        val h: Float,
        val text: String? = null,
        val color: Int = Color.BLACK,
        val points: List<PointF>? = null
    )
}

/**
 * Helper to find text positions on a page.
 */
class TextLocator(val targetPage: Int, val tapX: Float, val tapY: Float) : com.tom_roush.pdfbox.text.PDFTextStripper() {
    var bestMatch: RectF? = null
    private var minDist = Float.MAX_VALUE

    init {
        sortByPosition = true
        startPage = targetPage + 1
        endPage = targetPage + 1
    }

    fun getTextPositions(doc: com.tom_roush.pdfbox.pdmodel.PDDocument) {
        try {
            getText(doc)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun writeString(text: String?, textPositions: MutableList<com.tom_roush.pdfbox.text.TextPosition>?) {
        if (textPositions == null || textPositions.isEmpty()) return
        
        val currentWord = mutableListOf<com.tom_roush.pdfbox.text.TextPosition>()
        
        for (pos in textPositions) {
            val c = pos.unicode
            if (c == " " || c == "\t" || c == "\n" || c == "\r") {
                 checkWord(currentWord)
                 currentWord.clear()
            } else {
                currentWord.add(pos)
            }
        }
        checkWord(currentWord)
    }

    private fun checkWord(word: List<com.tom_roush.pdfbox.text.TextPosition>) {
        if (word.isEmpty()) return
        
        var minX = Float.MAX_VALUE
        var maxX = 0f
        var minY = Float.MAX_VALUE
        var maxY = 0f
        
        for (p in word) {
             minX = Math.min(minX, p.xDirAdj)
             maxX = Math.max(maxX, p.xDirAdj + p.width)
             minY = Math.min(minY, p.yDirAdj - p.height)
             maxY = Math.max(maxY, p.yDirAdj)
        }
        
        val wordRect = RectF(minX, minY, maxX, maxY)
        val touchRect = RectF(minX - 20, minY - 15, maxX + 20, maxY + 15)
        
        if (touchRect.contains(tapX, tapY)) {
             val distY = Math.abs(wordRect.centerY() - tapY)
             val distX = Math.abs(wordRect.centerX() - tapX)
             val dist = distY + distX
             
             if (dist < minDist) {
                 minDist = dist
                 bestMatch = wordRect
             }
        }
    }
}

/**
 * Helper to find text positions within a range on a page.
 */
class TextRangeLocator(val targetPage: Int, val x1: Float, val y1: Float, val x2: Float, val y2: Float) : com.tom_roush.pdfbox.text.PDFTextStripper() {
    val lineMatches = mutableListOf<RectF>()
    
    private val selectionRect = RectF(
        Math.min(x1, x2), Math.min(y1, y2),
        Math.max(x1, x2), Math.max(y1, y2)
    )

    init {
        sortByPosition = true
        startPage = targetPage + 1
        endPage = targetPage + 1
    }

    fun getTextPositions(doc: com.tom_roush.pdfbox.pdmodel.PDDocument) {
        try {
            getText(doc)
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun writeString(text: String?, textPositions: MutableList<com.tom_roush.pdfbox.text.TextPosition>?) {
        if (textPositions == null || textPositions.isEmpty()) return
        
        var lineMinX = Float.MAX_VALUE
        var lineMaxX = 0f
        var lineMinY = Float.MAX_VALUE
        var lineMaxY = 0f
        var foundInLine = false

        for (pos in textPositions) {
            val charRect = RectF(pos.xDirAdj, pos.yDirAdj - pos.height, pos.xDirAdj + pos.width, pos.yDirAdj)
            if (RectF.intersects(selectionRect, charRect)) {
                foundInLine = true
                lineMinX = Math.min(lineMinX, pos.xDirAdj)
                lineMaxX = Math.max(lineMaxX, pos.xDirAdj + pos.width)
                lineMinY = Math.min(lineMinY, pos.yDirAdj - pos.height)
                lineMaxY = Math.max(lineMaxY, pos.yDirAdj)
            }
        }

        if (foundInLine) {
            lineMatches.add(RectF(lineMinX, lineMinY, lineMaxX, lineMaxY))
        }
    }
}

object ArabicShaper {
    // Map of Arabic characters to their (Isolated, Initial, Medial, Final) forms
    private val SHAPING_MAP = mapOf(
        '\u0627' to charArrayOf('\uFE8D', '\u0627', '\u0627', '\uFE8E'), // ALIF
        '\u0628' to charArrayOf('\uFE8F', '\uFE91', '\uFE92', '\uFE90'), // BA
        '\u062A' to charArrayOf('\uFE95', '\uFE97', '\uFE98', '\uFE96'), // TA
        '\u062B' to charArrayOf('\uFE99', '\uFE9B', '\uFE9C', '\uFE9A'), // THA
        '\u062C' to charArrayOf('\uFE9D', '\uFE9F', '\uFEA0', '\uFE9E'), // JEEM
        '\u062D' to charArrayOf('\uFEA1', '\uFEA3', '\uFEA4', '\uFEA2'), // HAA
        '\u062E' to charArrayOf('\uFEA5', '\uFEA7', '\uFEA8', '\uFEA6'), // KHAA
        '\u062F' to charArrayOf('\uFEA9', '\u062F', '\u062F', '\uFEAA'), // DAL
        '\u0630' to charArrayOf('\uFEAB', '\u0630', '\u0630', '\uFEAC'), // THAL
        '\u0631' to charArrayOf('\uFEAD', '\u0631', '\u0631', '\uFEAE'), // RA
        '\u0632' to charArrayOf('\uFEAF', '\u0632', '\u0632', '\uFEB0'), // ZAY
        '\u0633' to charArrayOf('\uFEB1', '\uFEB3', '\uFEB4', '\uFEB2'), // SEEN
        '\u0634' to charArrayOf('\uFEB5', '\uFEB7', '\uFEB8', '\uFEB6'), // SHEEN
        '\u0635' to charArrayOf('\uFEB9', '\uFEBB', '\uFEBC', '\uFEBA'), // SAD
        '\u0636' to charArrayOf('\uFEBD', '\uFEBF', '\uFEC0', '\uFEBE'), // DAD
        '\u0637' to charArrayOf('\uFEC1', '\uFEC3', '\uFEC4', '\uFEC2'), // TAH
        '\u0638' to charArrayOf('\uFEC5', '\uFEC7', '\uFEC8', '\uFEC6'), // ZAH
        '\u0639' to charArrayOf('\uFEC9', '\uFECB', '\uFECC', '\uFECA'), // AIN
        '\u063A' to charArrayOf('\uFECD', '\uFECF', '\uFED0', '\uFECE'), // GHAIN
        '\u0641' to charArrayOf('\uFED1', '\uFED3', '\uFED4', '\uFED2'), // FA
        '\u0642' to charArrayOf('\uFED5', '\uFED7', '\uFED8', '\uFED6'), // QAF
        '\u0643' to charArrayOf('\uFED9', '\uFEDB', '\uFEDC', '\uFEDA'), // KAF
        '\u0644' to charArrayOf('\uFEDD', '\uFEDF', '\uFEE0', '\uFEDE'), // LAM
        '\u0645' to charArrayOf('\uFEE1', '\uFEE3', '\uFEE4', '\uFEE2'), // MEEM
        '\u0646' to charArrayOf('\uFEE5', '\uFEE7', '\uFEE8', '\uFEE6'), // NOON
        '\u0647' to charArrayOf('\uFEE9', '\uFEEB', '\uFEEC', '\uFEEA'), // HA
        '\u0648' to charArrayOf('\uFEED', '\u0648', '\u0648', '\uFEEE'), // WAW
        '\u064A' to charArrayOf('\uFEF1', '\uFEF3', '\uFEF4', '\uFEF2'), // YA
        '\u0626' to charArrayOf('\uFE89', '\uFE8B', '\uFE8C', '\uFE8A'), // YAA WITH HAMZA
        '\u0622' to charArrayOf('\uFE81', '\u0622', '\u0622', '\uFE82'), // ALIF WITH MADDA
        '\u0623' to charArrayOf('\uFE83', '\u0623', '\u0623', '\uFE84'), // ALIF WITH HAMZA ABOVE
        '\u0625' to charArrayOf('\uFE87', '\u0625', '\u0625', '\uFE88'), // ALIF WITH HAMZA BELOW
        '\u0624' to charArrayOf('\uFE85', '\u0624', '\u0624', '\uFE86'), // WAW WITH HAMZA
        '\u0649' to charArrayOf('\uFEEF', '\u0649', '\u0649', '\uFEF0'), // ALEF MAKSURA
        '\u0629' to charArrayOf('\uFE93', '\u0629', '\u0629', '\uFE94')  // TAA MARBUTA
    )

    fun shape(text: String): String {
        if (text.isEmpty()) return text
        
        // 1. Shaping (Char substitution)
        val shaped = shapeArabicForms(text)
        
        // 2. BiDi Reordering
        val bidi = Bidi(shaped, Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
        if (!bidi.isMixed && !bidi.isRightToLeft) return shaped
        
        val count = bidi.runCount
        val runs = mutableListOf<String>()
        for (i in 0 until count) {
            val start = bidi.getRunStart(i)
            val end = bidi.getRunLimit(i)
            var sub = shaped.substring(start, end)
            if (bidi.getRunLevel(i) % 2 != 0) {
                sub = sub.reversed()
            }
            runs.add(sub)
        }
        
        return if (bidi.isRightToLeft) runs.reversed().joinToString("") else runs.joinToString("")
    }

    private fun shapeArabicForms(text: String): String {
        val result = StringBuilder()
        for (i in 0 until text.length) {
            val c = text[i]
            val forms = SHAPING_MAP[c]
            if (forms == null) {
                result.append(c)
                continue
            }

            val prev = if (i > 0) text[i - 1] else null
            val next = if (i < text.length - 1) text[i + 1] else null

            val linkPrev = prev != null && canLinkLeft(prev)
            val linkNext = next != null && canLinkRight(next)

            val form = when {
                linkPrev && linkNext -> forms[2] // Medial
                linkPrev -> forms[3] // Final
                linkNext -> forms[1] // Initial
                else -> forms[0] // Isolated
            }
            result.append(form)
        }
        return result.toString()
    }

    private fun canLinkLeft(c: Char): Boolean {
        // Characters that can link with the following character
        val forms = SHAPING_MAP[c] ?: return false
        // Index 1 (Initial) or 2 (Medial) must not be original to be linkable right
        return forms[1] != c || forms[2] != c
    }

    private fun canLinkRight(c: Char): Boolean {
        // Characters that can link with the previous character
        return SHAPING_MAP.containsKey(c)
    }

    fun isArabic(c: Char): Boolean {
        return (c in '\u0600'..'\u06FF') || (c in '\u0750'..'\u077F') || 
               (c in '\u08A0'..'\u08FF') || (c in '\uFB50'..'\uFDFF') || 
               (c in '\uFE70'..'\uFEFF')
    }
}
