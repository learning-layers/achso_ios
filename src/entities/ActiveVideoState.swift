/*

ActiveVideoState is a snapshot of the state of an `ActiveVideo` (ActiveVideo.swift).
It is stored in a more compact way (contiguous arrays) than the video itself to make it less memory intensive to store many states.

Used to implament undo in the editing.

*/

import Foundation

class ActiveVideoState {
    typealias BatchPoint = (begin: Int, end: Int, time: Double)
    
    let annotations: [AnnotationBase]
    let batchPoints: [BatchPoint]
    
    init(batches: [AnnotationBatch]) {
        let annotationCount = batches.map({ $0.annotations.count }).reduce(0, combine: +)

        var annotations = [AnnotationBase]()
        var batchPoints = [BatchPoint]()
        
        annotations.reserveCapacity(annotationCount)
        batchPoints.reserveCapacity(batches.count)
        
        for batch in batches {
            batchPoints.append((begin: annotations.count, end: annotations.count + batch.annotations.count, batch.time))
            annotations.appendContentsOf(batch.annotations.map({ AnnotationBase(annotation: $0) }))
        }
        
        self.annotations = annotations
        self.batchPoints = batchPoints
    }
    
    var batches: [AnnotationBatch] {
        return batchPoints.map({ batchPoint -> AnnotationBatch in
            let annotations = self.annotations[batchPoint.begin..<batchPoint.end].map({
                return Annotation(annotationBase: $0)
            })
            return AnnotationBatch(time: batchPoint.time, annotations: annotations)
        })
    }
}
