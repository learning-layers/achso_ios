/*

`VideoCellView` represents one cell in the grid.

Uses [SDWebImage](https://github.com/rs/SDWebImage) to fetch and display the image.
Uses GradientLayer.swift for the gradient.

*/

import UIKit
import AVKit
import AVFoundation
import SDWebImage

class VideoViewCell: UICollectionViewCell {
    
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var thumbnailImageView: UIImageView!
    @IBOutlet weak var progressView: UIProgressView!
    @IBOutlet weak var sharedCloudImage: UIImageView!
    @IBOutlet weak var selectImage: UIImageView!
 
    // This is should reduce the amount the collection view relayouts when scrolling. Should be removed if the root cause of the relayouting is fixed.
    override func preferredLayoutAttributesFittingAttributes(layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        return layoutAttributes
    }
    
    var videoInfo: VideoInfo?
    static let gradient = makeGradient([
        GradientPoint(location: 0.0, color: hexCgColor(0x000000, alpha: 0.3)),
        GradientPoint(location: 1.0, color: hexCgColor(0x000000, alpha: 0.0)),
    ])
    let gradientLayer = GradientLayer(gradient: gradient)
    
    override func awakeFromNib() {
        self.thumbnailImageView.layer.addSublayer(self.gradientLayer)
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        self.gradientLayer.frame = layer.bounds
        self.gradientLayer.setNeedsDisplay()
    }
    
    func update(video: VideoInfo) {
        
        self.videoInfo = video
        
        // The thumbnails are complicated to render. This has been tested to improve the performance.
        self.layer.shouldRasterize = true
        self.layer.rasterizationScale = UIScreen.mainScreen().scale
        
        titleLabel?.text = video.title
        
        let imageName: String = {
            switch (video.isLocal, video.hasLocalModifications) {
            case (true, _): return "CloudLocal"
            case (false, false): return "CloudUploaded"
            case (false, true): return "CloudUploadedModified"
            }
        }()
        
        sharedCloudImage.image = UIImage(named: imageName)
        
        self.thumbnailImageView.alpha = 0.0
        if let url = video.thumbnailUri.realUrl {
            let options = SDWebImageOptions.RetryFailed
            thumbnailImageView.sd_setImageWithURL(url, placeholderImage: nil, options: options) { image, error, cacheType, url in
                
                if cacheType == .Memory {
                    // Set the alpha immediately if the image was already in memory. This stops flickering on refresh.
                    self.thumbnailImageView.alpha = self.currentImageAlpha
                } else {
                
                    // Fade in the image.
                    self.layer.shouldRasterize = false
                    UIView.transitionWithView(self.thumbnailImageView, duration: 0.2, options: UIViewAnimationOptions.CurveEaseOut,
                        animations: {
                            self.thumbnailImageView.alpha = self.currentImageAlpha
                        }, completion: { _ in
                            self.layer.shouldRasterize = true
                    })
                        
                }
            }
        }
        thumbnailImageView.contentMode = UIViewContentMode.ScaleAspectFill
        
        progressView.hidden = true
        progressView.progress = 0.0
    }
    
    func setSelectable(selectable: Bool) {
        self.selectImage.hidden = !selectable
    }
    
    func setProgress(progress: Float, animated: Bool) {
        // The progress view probably updates frequently so don't rasterize
        self.layer.shouldRasterize = false
        
        progressView.hidden = false
        progressView.setProgress(progress, animated: animated)
    }
    
    func clearProgress() {
        self.progressView.hidden = true
        progressView.progress = 0.0
        
        self.layer.shouldRasterize = true
    }
    
    var currentImageAlpha: CGFloat {
        return self.selected ? 0.5 : 1.0
    }
    
    override var selected: Bool {
        get {
            return super.selected
        }
        set {
            super.selected = newValue
            self.thumbnailImageView.alpha = self.currentImageAlpha
            self.selectImage.image = UIImage(named: newValue ? "checkcircle_filled_checked" : "checkcircle_hollow")
        }
    }
}
