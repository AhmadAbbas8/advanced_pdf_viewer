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
import android.widget.ImageView
import android.widget.TextView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.platform.PlatformView
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.Stack
import java.text.Bidi
import java.util.concurrent.Executors

import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPageContentStream
import com.tom_roush.pdfbox.pdmodel.interactive.annotation.PDAnnotationTextMarkup
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.font.PDType0Font
import com.tom_roush.pdfbox.pdmodel.font.PDFont
import com.tom_roush.pdfbox.pdmodel.graphics.state.PDExtendedGraphicsState
import com.tom_roush.pdfbox.pdmodel.graphics.blend.BlendMode
import com.tom_roush.pdfbox.io.MemoryUsageSetting
import com.tom_roush.pdfbox.text.PDFTextStripper
import com.tom_roush.pdfbox.text.TextPosition

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

    private val pdfRendererLock = Any()
    private val pdfBoxLock = Any()
    private var pdfRenderer: PdfRenderer? = null
    private var parcelFileDescriptor: ParcelFileDescriptor? = null
    private var interactionDocument: PDDocument? = null

    private var currentPath: String? = null
    private var currentTool: String = "none"
    private var isTempFile: Boolean = false

    private val renderExecutor = Executors.newFixedThreadPool(2)
    private val interactionExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var drawColor: Int = Color.RED
    private var highlightColor: Int = Color.YELLOW
    private var underlineColor: Int = Color.BLUE
    private var enablePageNumber: Boolean = false

    private var currentPage: Int = 0

    // Search state
    private var searchResults = mutableListOf<SearchMatch>()
    private var currentSearchIndex = -1

    private val undoStack = Stack<Annotation>()
    private val redoStack = Stack<Annotation>()

    private var currentScale: Float = 1.0f
    private var translateX: Float = 0f
    private var translateY: Float = 0f
    private val minScale: Float = 1.0f
    private val maxScale: Float = 5.0f

    // Search highlight colors — match iOS
    private val searchAllColor   = Color.argb(115, 255, 255,   0)  // yellow, ~45% alpha
    private val searchCurrentColor = Color.argb(178, 255, 128,   0)  // orange, ~70% alpha

    private val scaleDetector = ScaleGestureDetector(context, object : ScaleGestureDetector.SimpleOnScaleGestureListener() {
        override fun onScale(detector: ScaleGestureDetector): Boolean {
            val scaleFactor = detector.scaleFactor
            val prevScale = currentScale
            currentScale = currentScale * scaleFactor
            currentScale = currentScale.coerceIn(minScale, maxScale)
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
        }

        recyclerView.layoutManager = layoutManager
        recyclerView.adapter = PdfAdapter()
        recyclerView.setItemViewCacheSize(3)
        recyclerView.setHasFixedSize(true)

        recyclerView.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                super.onScrolled(recyclerView, dx, dy)
                val visiblePosition = layoutManager.findFirstVisibleItemPosition()
                if (visiblePosition >= 0 && visiblePosition != currentPage) {
                    currentPage = visiblePosition
                    mainHandler.post { methodChannel.invokeMethod("onPageChanged", currentPage) }
                }
            }
        })

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
        if (path != null) loadPdf(path)
    }

    override fun getView(): View = recyclerView

    override fun dispose() {
        pdfRenderer?.close()
        parcelFileDescriptor?.close()
        interactionExecutor.execute {
            try { interactionDocument?.close(); interactionDocument = null } catch (e: Exception) {}
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
            parcelFileDescriptor = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            pdfRenderer = PdfRenderer(parcelFileDescriptor!!)
            recyclerView.adapter?.notifyDataSetChanged()
            interactionExecutor.execute {
                try {
                    synchronized(pdfBoxLock) {
                        interactionDocument?.close()
                        interactionDocument = PDDocument.load(file, MemoryUsageSetting.setupTempFileOnly())
                    }
                } catch (e: Exception) { e.printStackTrace() }
            }
        } catch (e: Throwable) {
            System.err.println("PDF View Critical Error initializing PdfRenderer: ${e.message}")
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // RecyclerView Adapter
    // ─────────────────────────────────────────────────────────────────────────

    inner class PdfAdapter : RecyclerView.Adapter<PdfViewHolder>() {
        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PdfViewHolder {
            val container = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL
                layoutParams = RecyclerView.LayoutParams(RecyclerView.LayoutParams.MATCH_PARENT, RecyclerView.LayoutParams.WRAP_CONTENT)
                gravity = Gravity.CENTER_HORIZONTAL
            }
            val pdfView = AnnotationImageView(context, 0, 1, 1).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                adjustViewBounds = true
            }
            val pageNumView = TextView(context).apply {
                layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT)
                gravity = Gravity.CENTER
                setTextColor(Color.BLACK)
                textSize = 12f
                setPadding(0, 8, 0, 16)
            }
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

            var w = 0; var h = 0
            try {
                synchronized(pdfRendererLock) {
                    val page = renderer.openPage(position)
                    w = page.width; h = page.height; page.close()
                }
            } catch (e: Exception) { return }
            imageView.updatePageInfo(position, w, h)

            val cached = bitmapCache.get(position)
            if (cached != null) {
                imageView.setImageBitmap(cached)
            } else {
                imageView.setImageBitmap(null)
                renderExecutor.execute {
                    try {
                        val rend = pdfRenderer ?: return@execute
                        synchronized(pdfRendererLock) {
                            val page = rend.openPage(position)
                            var bitmap: Bitmap? = null
                            try {
                                val scale = 1.5f
                                bitmap = Bitmap.createBitmap((w * scale).toInt(), (h * scale).toInt(), Bitmap.Config.ARGB_8888)
                                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                            } catch (e: OutOfMemoryError) {
                                try {
                                    bitmap = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                                } catch (e2: OutOfMemoryError) { e2.printStackTrace() }
                            }
                            page.close()
                            if (bitmap != null) {
                                bitmapCache.put(position, bitmap)
                                mainHandler.post { if (imageView.pageIndex == position) imageView.setImageBitmap(bitmap) }
                            }
                        }
                    } catch (e: Exception) { e.printStackTrace() }
                }
            }
        }

        override fun getItemCount(): Int = pdfRenderer?.pageCount ?: 0
    }

    class PdfViewHolder(view: View) : RecyclerView.ViewHolder(view)

    // ─────────────────────────────────────────────────────────────────────────
    // Method Channel
    // ─────────────────────────────────────────────────────────────────────────

    private fun getIntArg(call: MethodCall, key: String): Int? = (call.argument<Any>(key) as? Number)?.toInt()
    private fun getDoubleArg(call: MethodCall, key: String): Double? = (call.argument<Any>(key) as? Number)?.toDouble()

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "setDrawingMode" -> {
                currentTool = call.argument<String>("tool") ?: "none"
                layoutManager.scrollable = currentTool == "none"
                result.success(null)
            }
            "setScrollLocked" -> {
                layoutManager.scrollable = !(call.argument<Boolean>("locked") ?: false)
                result.success(null)
            }
            "clearAnnotations" -> {
                undoStack.clear(); redoStack.clear(); refreshAllViews(); result.success(null)
            }
            "undo" -> {
                if (undoStack.isNotEmpty()) { redoStack.push(undoStack.pop()); refreshAllViews() }
                result.success(null)
            }
            "redo" -> {
                if (redoStack.isNotEmpty()) { undoStack.push(redoStack.pop()); refreshAllViews() }
                result.success(null)
            }
            "savePdf" -> savePdf(result)
            "addTextAnnotation" -> {
                val text = call.argument<String>("text")
                val x = getDoubleArg(call, "x")?.toFloat() ?: 0f
                val y = getDoubleArg(call, "y")?.toFloat() ?: 0f
                val pageIndex = getIntArg(call, "pageIndex") ?: 0
                val color = getIntArg(call, "color") ?: Color.BLACK
                if (text != null) { addAnnotation(Annotation(pageIndex, "text", x, y, 200f, 50f, text, color)); result.success(null) }
                else result.error("INVALID_ARGUMENTS", "Text is required", null)
            }
            "jumpToPage" -> {
                (layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(getIntArg(call, "page") ?: 0, 0)
                result.success(null)
            }
            "getTotalPages" -> result.success(pdfRenderer?.pageCount ?: 0)
            "updateConfig" -> {
                getIntArg(call, "drawColor")?.let { drawColor = it }
                getIntArg(call, "highlightColor")?.let { highlightColor = it }
                getIntArg(call, "underlineColor")?.let { underlineColor = it }
                call.argument<Boolean>("enablePageNumber")?.let { enablePageNumber = it; refreshAllViews() }
                result.success(null)
            }
            "zoomIn" -> {
                currentScale = (currentScale + 0.5f).coerceAtMost(maxScale); updateZoom(); result.success(null)
            }
            "zoomOut" -> {
                currentScale = (currentScale - 0.5f).coerceAtLeast(minScale)
                if (currentScale == 1.0f) { translateX = 0f; translateY = 0f }
                updateZoom(); result.success(null)
            }
            "setZoom" -> {
                currentScale = (getDoubleArg(call, "scale")?.toFloat() ?: 1.0f).coerceIn(minScale, maxScale)
                if (currentScale == 1.0f) { translateX = 0f; translateY = 0f }
                updateZoom(); result.success(null)
            }
            "getCurrentPage" -> result.success(currentPage)
            "searchText" -> {
                searchText(call.argument<String>("query") ?: ""); result.success(null)
            }
            "nextSearchResult" -> { nextSearchResult(); result.success(null) }
            "previousSearchResult" -> { previousSearchResult(); result.success(null) }
            "clearSearch" -> { clearSearch(); result.success(null) }
            else -> result.notImplemented()
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Zoom
    // ─────────────────────────────────────────────────────────────────────────

    private fun updateZoom() {
        if (currentScale > 1.0f) {
            val minTx = -(recyclerView.width * currentScale - recyclerView.width)
            val minTy = -(recyclerView.height * currentScale - recyclerView.height)
            translateX = translateX.coerceIn(minTx, 0f)
            translateY = translateY.coerceIn(minTy, 0f)
        } else { translateX = 0f; translateY = 0f }
        recyclerView.scaleX = currentScale; recyclerView.scaleY = currentScale
        recyclerView.translationX = translateX; recyclerView.translationY = translateY
        recyclerView.pivotX = 0f; recyclerView.pivotY = 0f
    }

    private fun addAnnotation(anno: Annotation) {
        undoStack.push(anno); redoStack.clear(); refreshAllViews()
    }

    private fun refreshAllViews() { recyclerView.adapter?.notifyDataSetChanged() }

    // ─────────────────────────────────────────────────────────────────────────
    // Save PDF
    // ─────────────────────────────────────────────────────────────────────────

    private fun setPdfBoxColor(cs: PDPageContentStream, color: Int, isNonStroking: Boolean) {
        val r = (color shr 16) and 0xFF
        val g = (color shr 8) and 0xFF
        val b = color and 0xFF
        if (isNonStroking) cs.setNonStrokingColor(r, g, b) else cs.setStrokingColor(r, g, b)
    }

    private fun drawMixedText(cs: PDPageContentStream, text: String, x: Float, y: Float,
                               pageHeight: Float, arabicFont: PDFont, latinFont: PDFont,
                               fontSize: Float, color: Int) {
        try {
            cs.beginText()
            setPdfBoxColor(cs, color, true)
            cs.newLineAtOffset(x, pageHeight - y)
            var run = StringBuilder(); var runIsArabic: Boolean? = null
            for (c in text) {
                val ca = ArabicNormalizer.isArabic(c)
                if (runIsArabic == null) { runIsArabic = ca; run.append(c) }
                else if (ca == runIsArabic) { run.append(c) }
                else {
                    cs.setFont(if (runIsArabic!!) arabicFont else latinFont, fontSize)
                    try { cs.showText(run.toString()) } catch (e: Exception) {
                        cs.setFont(if (runIsArabic!!) latinFont else arabicFont, fontSize)
                        cs.showText(run.toString())
                    }
                    run = StringBuilder().append(c); runIsArabic = ca
                }
            }
            if (run.isNotEmpty()) {
                cs.setFont(if (runIsArabic!!) arabicFont else latinFont, fontSize)
                try { cs.showText(run.toString()) } catch (e: Exception) {
                    cs.setFont(if (runIsArabic!!) latinFont else arabicFont, fontSize)
                    cs.showText(run.toString())
                }
            }
            cs.endText()
        } catch (e: Exception) { e.printStackTrace() } finally { cs.close() }
    }

    private fun savePdf(result: MethodChannel.Result) {
        val path = currentPath ?: return result.error("NO_PATH", "No PDF loaded", null)
        interactionExecutor.execute {
            var tempFile: File? = null
            try {
                synchronized(pdfBoxLock) {
                    try { interactionDocument?.close(); interactionDocument = null } catch (e: Exception) {}
                }
                runCatching { bitmapCache.evictAll(); System.gc(); Thread.sleep(100) }

                val document = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                try {
                    var font: PDFont? = null
                    try { font = PDType0Font.load(document, context.assets.open("flutter_assets/assets/fonts/Arial.ttf")) } catch (e: Exception) {}
                    if (font == null) {
                        for (fp in arrayOf("/system/fonts/Arial.ttf", "/system/fonts/NotoSansArabic-Regular.ttf",
                                           "/system/fonts/NotoNaskhArabic-Regular.ttf", "/system/fonts/DroidSansArabic.ttf")) {
                            val f = File(fp); if (f.exists()) { try { font = PDType0Font.load(document, f); break } catch (e: Exception) {} }
                        }
                    }
                    if (font == null) font = com.tom_roush.pdfbox.pdmodel.font.PDType1Font.HELVETICA_BOLD

                    for (anno in ArrayList(undoStack)) {
                        val page = document.getPage(anno.pageIndex)
                        val pageHeight = page.bBox.height
                        when (anno.type) {
                            "highlight" -> {
                                val cs = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                val gs = PDExtendedGraphicsState(); gs.nonStrokingAlphaConstant = 0.5f; gs.blendMode = BlendMode.MULTIPLY
                                cs.setGraphicsStateParameters(gs)
                                setPdfBoxColor(cs, anno.color, true)
                                cs.addRect(anno.x, pageHeight - anno.y - anno.h, anno.w, anno.h)
                                cs.fill(); cs.close()
                            }
                            "underline" -> {
                                val cs = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                setPdfBoxColor(cs, anno.color, false)
                                cs.setLineWidth(1.5f)
                                val pdfY = pageHeight - anno.y - anno.h
                                cs.moveTo(anno.x, pdfY); cs.lineTo(anno.x + anno.w, pdfY)
                                cs.stroke(); cs.close()
                            }
                            "text" -> {
                                val shapedText = ArabicShaper.shape(anno.text ?: "")
                                drawMixedText(
                                    PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true),
                                    shapedText, anno.x, anno.y, pageHeight,
                                    font!!, com.tom_roush.pdfbox.pdmodel.font.PDType1Font.HELVETICA_BOLD, 14f, anno.color
                                )
                            }
                            "draw" -> {
                                val points = anno.points ?: continue
                                if (points.size >= 2) {
                                    val cs = PDPageContentStream(document, page, PDPageContentStream.AppendMode.APPEND, true, true)
                                    setPdfBoxColor(cs, drawColor, false); cs.setLineWidth(2f)
                                    cs.moveTo(points[0].x, pageHeight - points[0].y)
                                    for (i in 1 until points.size) cs.lineTo(points[i].x, pageHeight - points[i].y)
                                    cs.stroke(); cs.close()
                                }
                            }
                        }
                    }
                    tempFile = File.createTempFile("saved_pdf_", ".pdf", context.cacheDir)
                    document.save(tempFile)
                } finally { document.close() }

                val bytes = tempFile.readBytes()
                synchronized(pdfBoxLock) {
                    interactionDocument = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly())
                }
                Handler(Looper.getMainLooper()).post { result.success(bytes) }
            } catch (e: Exception) {
                e.printStackTrace()
                try { synchronized(pdfBoxLock) { if (interactionDocument == null) interactionDocument = PDDocument.load(File(path), MemoryUsageSetting.setupTempFileOnly()) } } catch (ign: Exception) {}
                Handler(Looper.getMainLooper()).post { result.error("SAVE_ERROR", e.message, null) }
            } finally { tempFile?.delete() }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // AnnotationImageView
    // ─────────────────────────────────────────────────────────────────────────

    inner class AnnotationImageView(context: Context, var pageIndex: Int, var pdfWidth: Int, var pdfHeight: Int) : ImageView(context) {

        fun updatePageInfo(index: Int, width: Int, height: Int) {
            pageIndex = index; pdfWidth = width; pdfHeight = height; invalidate()
        }

        private var currentDrawingPath: Path? = null
        private var currentDrawingPoints = mutableListOf<PointF>()
        private var selectionStartPoint = PointF()
        private var selectionEndPoint = PointF()
        private var isSelecting = false

        private val drawPaint = Paint().apply {
            strokeWidth = 5f; style = Paint.Style.STROKE
            strokeJoin = Paint.Join.ROUND; strokeCap = Paint.Cap.ROUND; isAntiAlias = true
        }

        private fun getScale(): Float = if (width == 0) 1f else pdfWidth.toFloat() / width.toFloat()

        private val gestureDetector = GestureDetector(context, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                val scale = getScale()
                val x = e.x * scale; val y = e.y * scale
                return when (currentTool) {
                    "text" -> {
                        methodChannel.invokeMethod("onPdfTapped", mapOf("x" to x, "y" to y, "pageIndex" to pageIndex))
                        true
                    }
                    "highlight", "underline" -> { snapToText(x, y); true }
                    else -> false
                }
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
                                val yOffset = if (currentTool == "highlight") 0f else bounds.height() - 2f
                                addAnnotation(Annotation(pageIndex, currentTool, bounds.left, bounds.top + yOffset,
                                    bounds.width(), if (currentTool == "highlight") bounds.height() else 4f,
                                    null, if (currentTool == "highlight") highlightColor else underlineColor))
                            } else {
                                val h = if (currentTool == "highlight") 30f else 6f
                                addAnnotation(Annotation(pageIndex, currentTool, x - 100, y - h / 4, 200f, h / 2,
                                    null, if (currentTool == "highlight") highlightColor else underlineColor))
                            }
                        }
                    }
                } catch (e: Exception) { e.printStackTrace() }
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
                                matches.forEach { bounds ->
                                    val yOffset = if (currentTool == "highlight") 0f else bounds.height() - 2f
                                    addAnnotation(Annotation(pageIndex, currentTool, bounds.left, bounds.top + yOffset,
                                        bounds.width(), if (currentTool == "highlight") bounds.height() else 4f,
                                        null, if (currentTool == "highlight") highlightColor else underlineColor))
                                }
                            } else {
                                val left = minOf(x1, x2); val top = minOf(y1, y2)
                                val w = maxOf(x1, x2) - left; val h = if (currentTool == "highlight") maxOf(y1, y2) - top else 6f
                                addAnnotation(Annotation(pageIndex, currentTool, left, top, maxOf(w, 50f), maxOf(h, 20f),
                                    null, if (currentTool == "highlight") highlightColor else underlineColor))
                            }
                        }
                    }
                } catch (e: Exception) { e.printStackTrace() }
            }
        }

        override fun onTouchEvent(event: MotionEvent?): Boolean {
            if (event != null && gestureDetector.onTouchEvent(event)) return true
            if (currentTool == "none") return super.onTouchEvent(event)
            val scale = getScale()
            val x = event?.x ?: 0f; val y = event?.y ?: 0f
            when (event?.action) {
                MotionEvent.ACTION_DOWN -> {
                    if (currentTool == "draw") {
                        currentDrawingPath = Path().apply { moveTo(x, y) }
                        currentDrawingPoints.clear(); currentDrawingPoints.add(PointF(x * scale, y * scale))
                    } else if (currentTool == "highlight" || currentTool == "underline") {
                        selectionStartPoint.set(x * scale, y * scale); selectionEndPoint.set(x * scale, y * scale); isSelecting = true
                    }
                    invalidate(); return true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (currentTool == "draw") {
                        currentDrawingPath?.lineTo(x, y); currentDrawingPoints.add(PointF(x * scale, y * scale))
                    } else if (isSelecting) selectionEndPoint.set(x * scale, y * scale)
                    invalidate(); return true
                }
                MotionEvent.ACTION_UP -> {
                    if (currentTool == "draw") {
                        if (currentDrawingPoints.isNotEmpty()) addAnnotation(Annotation(pageIndex, "draw", 0f, 0f, 0f, 0f, null, drawColor, ArrayList(currentDrawingPoints)))
                        currentDrawingPath = null; currentDrawingPoints.clear()
                    } else if (isSelecting) {
                        isSelecting = false
                        snapToTextRange(selectionStartPoint.x, selectionStartPoint.y, selectionEndPoint.x, selectionEndPoint.y)
                    }
                    invalidate(); return true
                }
            }
            return true
        }

        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val scale = getScale()
            if (scale == 0f) return
            val invScale = 1f / scale

            // ── Draw search highlights ──────────────────────────────────────
            val allPaint   = Paint().apply { color = searchAllColor;    style = Paint.Style.FILL }
            val curPaint   = Paint().apply { color = searchCurrentColor; style = Paint.Style.FILL }
            for (i in searchResults.indices) {
                val match = searchResults[i]
                if (match.pageIndex != pageIndex) continue
                val paint = if (i == currentSearchIndex) curPaint else allPaint
                canvas.drawRect(
                    match.rect.left   * invScale, match.rect.top    * invScale,
                    match.rect.right  * invScale, match.rect.bottom * invScale, paint
                )
            }

            // ── Draw user annotations ───────────────────────────────────────
            for (anno in undoStack) {
                if (anno.pageIndex != pageIndex) continue
                when (anno.type) {
                    "text" -> {
                        val tp = Paint().apply { color = anno.color; textSize = 14f * invScale; isFakeBoldText = true }
                        canvas.drawText(anno.text ?: "", anno.x * invScale, anno.y * invScale, tp)
                    }
                    "highlight" -> {
                        val p = Paint().apply { color = anno.color; alpha = 100; style = Paint.Style.FILL }
                        canvas.drawRect(anno.x * invScale, anno.y * invScale, (anno.x + anno.w) * invScale, (anno.y + anno.h) * invScale, p)
                    }
                    "underline" -> {
                        val p = Paint().apply { color = anno.color; strokeWidth = 2f * invScale; style = Paint.Style.STROKE }
                        canvas.drawLine(anno.x * invScale, (anno.y + anno.h) * invScale, (anno.x + anno.w) * invScale, (anno.y + anno.h) * invScale, p)
                    }
                    "draw" -> {
                        val points = anno.points ?: continue
                        if (points.size < 2) continue
                        val p = Paint(drawPaint).apply { color = anno.color; strokeWidth = 2f * invScale }
                        val path = Path().apply {
                            moveTo(points[0].x * invScale, points[0].y * invScale)
                            for (i in 1 until points.size) lineTo(points[i].x * invScale, points[i].y * invScale)
                        }
                        canvas.drawPath(path, p)
                    }
                }
            }

            // ── Active drawing stroke ───────────────────────────────────────
            currentDrawingPath?.let { canvas.drawPath(it, drawPaint.apply { color = drawColor; strokeWidth = 5f }) }

            // ── Selection feedback rectangle ────────────────────────────────
            if (isSelecting) {
                val p = Paint().apply {
                    color = if (currentTool == "highlight") highlightColor else underlineColor
                    alpha = 128; style = Paint.Style.FILL
                }
                canvas.drawRect(
                    minOf(selectionStartPoint.x, selectionEndPoint.x) * invScale,
                    minOf(selectionStartPoint.y, selectionEndPoint.y) * invScale,
                    maxOf(selectionStartPoint.x, selectionEndPoint.x) * invScale,
                    maxOf(selectionStartPoint.y, selectionEndPoint.y) * invScale, p
                )
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Data classes
    // ─────────────────────────────────────────────────────────────────────────

    data class Annotation(
        val pageIndex: Int, val type: String,
        val x: Float, val y: Float, val w: Float, val h: Float,
        val text: String? = null, val color: Int = Color.BLACK,
        val points: List<PointF>? = null
    )

    class SearchMatch(val pageIndex: Int, val rect: RectF)

    // ─────────────────────────────────────────────────────────────────────────
    // Arabic Search Engine
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Runs a normalized Arabic search across all pages.
     *
     * KEY FIX vs original code:
     * The old SearchStripper used PDFTextStripper.writeString() which is called
     * once per "text run" — a chunk as small as 1 character. Arabic words split
     * across runs were never matched. We now use a PageTextCollector that overrides
     * processTextPosition() to collect ALL TextPositions for the full page into one
     * list, then run our own normalized string search over the concatenated text.
     *
     * Also fixes:
     * - Forward-first strategy (reversed only as fallback) prevents wrong positions
     * - Full ArabicNormalizer coverage (Farsi Yeh, Heh Goal, tatweel, ZW chars)
     * - No trailing \\s* per char (was causing false positives)
     */
    private fun searchText(query: String) {
        clearSearch()
        if (query.isEmpty()) return

        interactionExecutor.execute {
            val document = interactionDocument ?: return@execute
            val results = mutableListOf<SearchMatch>()
            try {
                synchronized(pdfBoxLock) {
                    val isArabic = query.any { ArabicNormalizer.isArabic(it) }
                    val queryNorm = ArabicNormalizer.normalize(query).trim()

                    for (pageIndex in 0 until document.numberOfPages) {
                        val pageMatches = if (isArabic) {
                            arabicSearchPage(document, pageIndex, queryNorm)
                        } else {
                            latinSearchPage(document, pageIndex, query)
                        }
                        results.addAll(pageMatches)
                    }
                }

                mainHandler.post {
                    searchResults.addAll(results)
                    currentSearchIndex = if (searchResults.isNotEmpty()) 0 else -1
                    if (searchResults.isNotEmpty()) jumpToMatch(searchResults[0])
                    refreshAllViews()
                    notifySearchResults()
                }
            } catch (e: Exception) { e.printStackTrace() }
        }
    }

    /**
     * Collects all TextPositions on a page, then runs normalized Arabic search.
     * Uses forward-first strategy: try logical order first, fall back to reversed
     * only if forward finds nothing (prevents wrong-position highlights).
     */
    private fun arabicSearchPage(document: PDDocument, pageIndex: Int, queryNorm: String): List<SearchMatch> {
        val collector = PageTextCollector(pageIndex)
        try { collector.getText(document) } catch (e: Exception) { e.printStackTrace(); return emptyList() }
        if (collector.positions.isEmpty()) return emptyList()

        // Build the normalization map for the full page text
        val rawChars = collector.positions.map { it.unicode?.firstOrNull() ?: '\u0000' }
        val mapping  = ArabicNormalizer.buildNormalizationMap(rawChars)
        val pageNorm = mapping.normalizedText
        if (pageNorm.isEmpty()) return emptyList()

        val queryRev      = queryNorm.reversed()
        val queryRevWords = ArabicNormalizer.reverseWords(queryNorm)

        // Step 1: forward search
        val forwardRanges = findAll(queryNorm, pageNorm)
        if (forwardRanges.isNotEmpty()) {
            return forwardRanges.mapNotNull { range ->
                rectsFromNormRange(range, mapping, collector.positions, pageIndex)
            }
        }

        // Step 2: reversed variants (only when forward finds nothing)
        val reversedRanges = mutableListOf<IntRange>()
        reversedRanges.addAll(findAll(queryRev, pageNorm))
        if (queryRevWords != queryNorm && queryRevWords != queryRev) {
            reversedRanges.addAll(findAll(queryRevWords, pageNorm))
        }

        return reversedRanges.mapNotNull { range ->
            rectsFromNormRange(range, mapping, collector.positions, pageIndex)
        }.deduplicated()
    }

    /** Simple case-insensitive Latin search on full page text. */
    private fun latinSearchPage(document: PDDocument, pageIndex: Int, query: String): List<SearchMatch> {
        val collector = PageTextCollector(pageIndex)
        try { collector.getText(document) } catch (e: Exception) { return emptyList() }
        if (collector.positions.isEmpty()) return emptyList()

        val rawChars = collector.positions.map { it.unicode?.firstOrNull() ?: '\u0000' }
        val fullText = String(rawChars.toCharArray())
        val lowerText  = fullText.lowercase()
        val lowerQuery = query.lowercase()

        val results = mutableListOf<SearchMatch>()
        var start = 0
        while (start < lowerText.length) {
            val idx = lowerText.indexOf(lowerQuery, start)
            if (idx == -1) break
            val end = idx + lowerQuery.length - 1
            val rect = boundsFromPositions(collector.positions, idx, end) ?: continue
            results.add(SearchMatch(pageIndex, rect))
            start = idx + 1
        }
        return results
    }

    /** Finds all non-overlapping occurrences of [pattern] in [text] (case-insensitive). */
    private fun findAll(pattern: String, text: String): List<IntRange> {
        if (pattern.isEmpty() || text.isEmpty()) return emptyList()
        val lower = text.lowercase(); val lp = pattern.lowercase()
        val ranges = mutableListOf<IntRange>()
        var i = 0
        while (i <= lower.length - lp.length) {
            if (lower.startsWith(lp, i)) { ranges.add(i until i + lp.length); i += lp.length } else i++
        }
        return ranges
    }

    /**
     * Maps a range in normalized text back to TextPosition indices,
     * then computes a bounding RectF from those TextPositions.
     */
    private fun rectsFromNormRange(normRange: IntRange, mapping: ArabicNormalizer.NormMap,
                                    positions: List<TextPosition>, pageIndex: Int): SearchMatch? {
        val origStart = mapping.normToOrig.getOrNull(normRange.first) ?: return null
        val origEnd   = mapping.normToOrig.getOrNull(normRange.last)  ?: return null
        val actualStart = minOf(origStart, origEnd)
        val actualEnd   = maxOf(origStart, origEnd)
        val rect = boundsFromPositions(positions, actualStart, actualEnd) ?: return null
        return SearchMatch(pageIndex, rect)
    }

    /** Computes a RectF bounding box from a slice of TextPositions. */
    private fun boundsFromPositions(positions: List<TextPosition>, start: Int, end: Int): RectF? {
        if (start > end || end >= positions.size || start < 0) return null
        var minX = Float.MAX_VALUE; var maxX = -Float.MAX_VALUE
        var minY = Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
        for (i in start..end) {
            val pos = positions[i]
            if (pos.unicode?.trim().isNullOrEmpty() && (end - start) > 0) continue
            val x0 = pos.xDirAdj; val x1 = pos.xDirAdj + pos.width
            val y0 = pos.yDirAdj - pos.height; val y1 = pos.yDirAdj
            minX = minOf(minX, x0, x1); maxX = maxOf(maxX, x0, x1)
            minY = minOf(minY, y0, y1); maxY = maxOf(maxY, y0, y1)
        }
        if (minX >= maxX || minY >= maxY) return null
        return RectF(minX, minY, maxX, maxY)
    }

    private fun List<SearchMatch>.deduplicated(): List<SearchMatch> {
        val unique = mutableListOf<SearchMatch>()
        for (m in this) {
            val dup = unique.any { it.pageIndex == m.pageIndex &&
                Math.abs(it.rect.left - m.rect.left) < 4f && Math.abs(it.rect.top - m.rect.top) < 4f }
            if (!dup) unique.add(m)
        }
        return unique
    }

    private fun nextSearchResult() {
        if (searchResults.isEmpty()) return
        currentSearchIndex = (currentSearchIndex + 1) % searchResults.size
        jumpToMatch(searchResults[currentSearchIndex])
        refreshAllViews(); notifySearchResults()
    }

    private fun previousSearchResult() {
        if (searchResults.isEmpty()) return
        currentSearchIndex = (currentSearchIndex - 1 + searchResults.size) % searchResults.size
        jumpToMatch(searchResults[currentSearchIndex])
        refreshAllViews(); notifySearchResults()
    }

    private fun clearSearch() {
        searchResults.clear(); currentSearchIndex = -1; refreshAllViews(); notifySearchResults()
    }

    private fun jumpToMatch(match: SearchMatch) {
        (layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(match.pageIndex, 0)
    }

    private fun notifySearchResults() {
        mainHandler.post {
            methodChannel.invokeMethod("onSearchResultsChanged", mapOf(
                "current" to currentSearchIndex + 1, "total" to searchResults.size
            ))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // PageTextCollector — collects ALL TextPositions for a page in one list
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Extends PDFTextStripper to collect every individual TextPosition on a page.
     *
     * WHY: PDFTextStripper.writeString() is called once per text run (can be 1 char).
     * Arabic words are frequently split across multiple runs in the PDF stream.
     * By overriding processTextPosition() we get every character individually,
     * so we can build the full page text and search across run boundaries.
     */
    class PageTextCollector(pageIndex: Int) : PDFTextStripper() {
        val positions = mutableListOf<TextPosition>()
        init {
            sortByPosition = true
            startPage = pageIndex + 1
            endPage   = pageIndex + 1
        }
        override fun processTextPosition(text: TextPosition) {
            positions.add(text)
        }
        // writeString is still required by the base class machinery
        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) { }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // TextLocator / TextRangeLocator (unchanged from original — still needed
    // for tap-to-highlight and drag-to-highlight)
    // ─────────────────────────────────────────────────────────────────────────

    class TextLocator(val targetPage: Int, val tapX: Float, val tapY: Float) : PDFTextStripper() {
        var bestMatch: RectF? = null
        private var minDist = Float.MAX_VALUE
        init { sortByPosition = true; startPage = targetPage + 1; endPage = targetPage + 1 }
        fun getTextPositions(doc: PDDocument) { try { getText(doc) } catch (e: Exception) { e.printStackTrace() } }
        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) {
            if (textPositions == null || textPositions.isEmpty()) return
            val word = mutableListOf<TextPosition>()
            for (pos in textPositions) {
                val c = pos.unicode
                if (c == " " || c == "\t" || c == "\n" || c == "\r") { checkWord(word); word.clear() } else word.add(pos)
            }
            checkWord(word)
        }
        private fun checkWord(word: List<TextPosition>) {
            if (word.isEmpty()) return
            var minX = Float.MAX_VALUE; var maxX = 0f; var minY = Float.MAX_VALUE; var maxY = 0f
            for (p in word) { minX = minOf(minX, p.xDirAdj); maxX = maxOf(maxX, p.xDirAdj + p.width); minY = minOf(minY, p.yDirAdj - p.height); maxY = maxOf(maxY, p.yDirAdj) }
            val wr = RectF(minX, minY, maxX, maxY)
            val tr = RectF(minX - 20, minY - 15, maxX + 20, maxY + 15)
            if (tr.contains(tapX, tapY)) {
                val dist = Math.abs(wr.centerY() - tapY) + Math.abs(wr.centerX() - tapX)
                if (dist < minDist) { minDist = dist; bestMatch = wr }
            }
        }
    }

    class TextRangeLocator(val targetPage: Int, val x1: Float, val y1: Float, val x2: Float, val y2: Float) : PDFTextStripper() {
        val lineMatches = mutableListOf<RectF>()
        private val selectionRect = RectF(minOf(x1, x2), minOf(y1, y2), maxOf(x1, x2), maxOf(y1, y2))
        init { sortByPosition = true; startPage = targetPage + 1; endPage = targetPage + 1 }
        fun getTextPositions(doc: PDDocument) { try { getText(doc) } catch (e: Exception) { e.printStackTrace() } }
        override fun writeString(text: String?, textPositions: MutableList<TextPosition>?) {
            if (textPositions == null || textPositions.isEmpty()) return
            var minX = Float.MAX_VALUE; var maxX = 0f; var minY = Float.MAX_VALUE; var maxY = 0f; var found = false
            for (pos in textPositions) {
                val cr = RectF(pos.xDirAdj, pos.yDirAdj - pos.height, pos.xDirAdj + pos.width, pos.yDirAdj)
                if (RectF.intersects(selectionRect, cr)) {
                    found = true
                    minX = minOf(minX, pos.xDirAdj); maxX = maxOf(maxX, pos.xDirAdj + pos.width)
                    minY = minOf(minY, pos.yDirAdj - pos.height); maxY = maxOf(maxY, pos.yDirAdj)
                }
            }
            if (found) lineMatches.add(RectF(minX, minY, maxX, maxY))
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ArabicNormalizer — mirrors iOS ArabicNormalizer exactly
    // ─────────────────────────────────────────────────────────────────────────

    object ArabicNormalizer {

        fun isArabic(c: Char): Boolean {
            val v = c.code
            return (v in 0x0600..0x06FF) || (v in 0x0750..0x077F) ||
                   (v in 0x08A0..0x08FF) || (v in 0xFB50..0xFDFF) || (v in 0xFE70..0xFEFF)
        }

        /** Presentation Forms B → base Unicode */
        private val PRESENTATION_TO_BASE: Map<Int, Int> = buildMap {
            val entries = listOf(
                0x0627 to listOf(0xFE8D, 0xFE8E),
                0x0628 to listOf(0xFE8F, 0xFE90, 0xFE91, 0xFE92),
                0x062A to listOf(0xFE95, 0xFE96, 0xFE97, 0xFE98),
                0x062B to listOf(0xFE99, 0xFE9A, 0xFE9B, 0xFE9C),
                0x062C to listOf(0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0),
                0x062D to listOf(0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4),
                0x062E to listOf(0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8),
                0x062F to listOf(0xFEA9, 0xFEAA),
                0x0630 to listOf(0xFEAB, 0xFEAC),
                0x0631 to listOf(0xFEAD, 0xFEAE),
                0x0632 to listOf(0xFEAF, 0xFEB0),
                0x0633 to listOf(0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4),
                0x0634 to listOf(0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8),
                0x0635 to listOf(0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC),
                0x0636 to listOf(0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0),
                0x0637 to listOf(0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4),
                0x0638 to listOf(0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8),
                0x0639 to listOf(0xFEC9, 0xFECA, 0xFECB, 0xFECC),
                0x063A to listOf(0xFECD, 0xFECE, 0xFECF, 0xFED0),
                0x0641 to listOf(0xFED1, 0xFED2, 0xFED3, 0xFED4),
                0x0642 to listOf(0xFED5, 0xFED6, 0xFED7, 0xFED8),
                0x0643 to listOf(0xFED9, 0xFEDA, 0xFEDB, 0xFEDC),
                0x0644 to listOf(0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0),
                0x0645 to listOf(0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4),
                0x0646 to listOf(0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8),
                0x0647 to listOf(0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC),
                0x0648 to listOf(0xFEED, 0xFEEE),
                0x064A to listOf(0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4),
                0x0626 to listOf(0xFE89, 0xFE8A, 0xFE8B, 0xFE8C),
                0x0622 to listOf(0xFE81, 0xFE82),
                0x0623 to listOf(0xFE83, 0xFE84),
                0x0625 to listOf(0xFE87, 0xFE88),
                0x0624 to listOf(0xFE85, 0xFE86),
                0x0649 to listOf(0xFEEF, 0xFEF0),
                0x0629 to listOf(0xFE93, 0xFE94)
            )
            for ((base, forms) in entries) for (f in forms) put(f, base)
        }

        /** Lam-alef ligatures expand to 2 chars */
        private val LAM_ALEF: Map<Int, Pair<Int, Int>> = mapOf(
            0xFEF5 to (0x0644 to 0x0622), 0xFEF6 to (0x0644 to 0x0622),
            0xFEF7 to (0x0644 to 0x0623), 0xFEF8 to (0x0644 to 0x0623),
            0xFEF9 to (0x0644 to 0x0625), 0xFEFA to (0x0644 to 0x0625),
            0xFEFB to (0x0644 to 0x0627), 0xFEFC to (0x0644 to 0x0627)
        )

        /** Codepoints to strip (diacritics, tatweel, invisible marks) */
        private val STRIP_SET: Set<Int> = buildSet {
            addAll(0x064B..0x065F)   // harakat
            add(0x0670)              // superscript alef
            addAll(0x06D6..0x06DC)  // Quranic annotation
            addAll(0x06DF..0x06E4)
            add(0x06E7); add(0x06E8)
            addAll(0x06EA..0x06ED)
            addAll(0x0610..0x061A)  // extended marks
            add(0x0640)             // tatweel
            add(0x200C); add(0x200D); add(0x200E); add(0x200F); add(0xFEFF)
        }

        data class NormMap(val normalizedText: String, val normToOrig: List<Int>)

        /**
         * Builds the normalised text AND the normToOrig index mapping in a single pass.
         * Input is a list of Chars (one per TextPosition).
         * normToOrig[i] = index into the original positions list for normalised char i.
         */
        fun buildNormalizationMap(chars: List<Char>): NormMap {
            val norm     = StringBuilder()
            val n2o      = mutableListOf<Int>()

            for ((i, c) in chars.withIndex()) {
                val v = c.code

                // 1. Strip diacritics, tatweel, invisible marks
                if (v in STRIP_SET) continue

                // 2. Expand lam-alef ligatures (1 orig → 2 norm)
                val la = LAM_ALEF[v]
                if (la != null) {
                    norm.append(la.first.toChar()); n2o.add(i)
                    norm.append(la.second.toChar()); n2o.add(i)
                    continue
                }

                // 3. Unshape presentation forms → base
                val base = PRESENTATION_TO_BASE[v]
                if (base != null) { norm.append(base.toChar()); n2o.add(i); continue }

                // 4. Keep as-is (unification applied below)
                norm.append(c); n2o.add(i)
            }

            // 5. Letter unification (all 1:1, indices stay valid)
            val unified = norm.toString()
                .replace('\u0622', '\u0627').replace('\u0623', '\u0627')
                .replace('\u0625', '\u0627').replace('\u0671', '\u0627')
                .replace('\u0672', '\u0627').replace('\u0673', '\u0627')
                .replace('\u0629', '\u0647')   // ة → ه
                .replace('\u06C1', '\u0647')   // ہ → ه (Heh Goal)
                .replace('\u0649', '\u064A')   // ى → ي
                .replace('\u06CC', '\u064A')   // ی → ي (Farsi Yeh — critical for Quran PDFs)
                .replace('\u06D2', '\u064A')   // ے → ي
                .replace('\u0624', '\u0648')   // ؤ → و
                .replace('\u0626', '\u064A')   // ئ → ي

            return NormMap(unified, n2o)
        }

        /** Normalizes a String (for normalising the query). */
        fun normalize(text: String): String {
            val chars = text.map { it }
            return buildNormalizationMap(chars).normalizedText
        }

        /** Reverses word order (keeps char order within each word). */
        fun reverseWords(text: String): String =
            text.split(" ").reversed().joinToString(" ")
    }

    // ─────────────────────────────────────────────────────────────────────────
    // ArabicShaper — kept for savePdf text rendering (unchanged from original)
    // ─────────────────────────────────────────────────────────────────────────

    object ArabicShaper {
        private val SHAPING_MAP = mapOf(
            '\u0627' to charArrayOf('\uFE8D', '\u0627', '\u0627', '\uFE8E'),
            '\u0628' to charArrayOf('\uFE8F', '\uFE91', '\uFE92', '\uFE90'),
            '\u062A' to charArrayOf('\uFE95', '\uFE97', '\uFE98', '\uFE96'),
            '\u062B' to charArrayOf('\uFE99', '\uFE9B', '\uFE9C', '\uFE9A'),
            '\u062C' to charArrayOf('\uFE9D', '\uFE9F', '\uFEA0', '\uFE9E'),
            '\u062D' to charArrayOf('\uFEA1', '\uFEA3', '\uFEA4', '\uFEA2'),
            '\u062E' to charArrayOf('\uFEA5', '\uFEA7', '\uFEA8', '\uFEA6'),
            '\u062F' to charArrayOf('\uFEA9', '\u062F', '\u062F', '\uFEAA'),
            '\u0630' to charArrayOf('\uFEAB', '\u0630', '\u0630', '\uFEAC'),
            '\u0631' to charArrayOf('\uFEAD', '\u0631', '\u0631', '\uFEAE'),
            '\u0632' to charArrayOf('\uFEAF', '\u0632', '\u0632', '\uFEB0'),
            '\u0633' to charArrayOf('\uFEB1', '\uFEB3', '\uFEB4', '\uFEB2'),
            '\u0634' to charArrayOf('\uFEB5', '\uFEB7', '\uFEB8', '\uFEB6'),
            '\u0635' to charArrayOf('\uFEB9', '\uFEBB', '\uFEBC', '\uFEBA'),
            '\u0636' to charArrayOf('\uFEBD', '\uFEBF', '\uFEC0', '\uFEBE'),
            '\u0637' to charArrayOf('\uFEC1', '\uFEC3', '\uFEC4', '\uFEC2'),
            '\u0638' to charArrayOf('\uFEC5', '\uFEC7', '\uFEC8', '\uFEC6'),
            '\u0639' to charArrayOf('\uFEC9', '\uFECB', '\uFECC', '\uFECA'),
            '\u063A' to charArrayOf('\uFECD', '\uFECF', '\uFED0', '\uFECE'),
            '\u0641' to charArrayOf('\uFED1', '\uFED3', '\uFED4', '\uFED2'),
            '\u0642' to charArrayOf('\uFED5', '\uFED7', '\uFED8', '\uFED6'),
            '\u0643' to charArrayOf('\uFED9', '\uFEDB', '\uFEDC', '\uFEDA'),
            '\u0644' to charArrayOf('\uFEDD', '\uFEDF', '\uFEE0', '\uFEDE'),
            '\u0645' to charArrayOf('\uFEE1', '\uFEE3', '\uFEE4', '\uFEE2'),
            '\u0646' to charArrayOf('\uFEE5', '\uFEE7', '\uFEE8', '\uFEE6'),
            '\u0647' to charArrayOf('\uFEE9', '\uFEEB', '\uFEEC', '\uFEEA'),
            '\u0648' to charArrayOf('\uFEED', '\u0648', '\u0648', '\uFEEE'),
            '\u064A' to charArrayOf('\uFEF1', '\uFEF3', '\uFEF4', '\uFEF2'),
            '\u0626' to charArrayOf('\uFE89', '\uFE8B', '\uFE8C', '\uFE8A'),
            '\u0622' to charArrayOf('\uFE81', '\u0622', '\u0622', '\uFE82'),
            '\u0623' to charArrayOf('\uFE83', '\u0623', '\u0623', '\uFE84'),
            '\u0625' to charArrayOf('\uFE87', '\u0625', '\u0625', '\uFE88'),
            '\u0624' to charArrayOf('\uFE85', '\u0624', '\u0624', '\uFE86'),
            '\u0649' to charArrayOf('\uFEEF', '\u0649', '\u0649', '\uFEF0'),
            '\u0629' to charArrayOf('\uFE93', '\u0629', '\u0629', '\uFE94')
        )

        fun shape(text: String): String {
            if (text.isEmpty()) return text
            val shaped = shapeArabicForms(text)
            val bidi = Bidi(shaped, Bidi.DIRECTION_DEFAULT_LEFT_TO_RIGHT)
            if (!bidi.isMixed && !bidi.isRightToLeft) return shaped
            val runs = mutableListOf<String>()
            for (i in 0 until bidi.runCount) {
                var sub = shaped.substring(bidi.getRunStart(i), bidi.getRunLimit(i))
                if (bidi.getRunLevel(i) % 2 != 0) sub = sub.reversed()
                runs.add(sub)
            }
            return if (bidi.isRightToLeft) runs.reversed().joinToString("") else runs.joinToString("")
        }

        private fun shapeArabicForms(text: String): String {
            val result = StringBuilder()
            for (i in text.indices) {
                val c = text[i]; val forms = SHAPING_MAP[c]
                if (forms == null) { result.append(c); continue }
                val prev = if (i > 0) text[i - 1] else null
                val next = if (i < text.length - 1) text[i + 1] else null
                result.append(when {
                    prev != null && canLinkLeft(prev) && next != null && canLinkRight(next) -> forms[2]
                    prev != null && canLinkLeft(prev) -> forms[3]
                    next != null && canLinkRight(next) -> forms[1]
                    else -> forms[0]
                })
            }
            return result.toString()
        }

        private fun canLinkLeft(c: Char) = SHAPING_MAP[c]?.let { it[1] != c || it[2] != c } ?: false
        private fun canLinkRight(c: Char) = SHAPING_MAP.containsKey(c)
    }
}