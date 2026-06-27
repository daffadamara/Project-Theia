#pragma once
#include "Node.hpp"

namespace theia {

// Filter node (1 input): remap the input's actual [min,max] to [0,1]. Useful
// after erosion, which can drift the range. No params.
class NormalizeNode : public Node {
public:
    explicit NormalizeNode(std::string id) : Node(std::move(id), "normalize") {}
    std::size_t inputCount() const override { return 1; }
    bool evaluate(GPUContext& ctx,
                  const std::vector<const Heightfield*>& inputs,
                  Heightfield& out, std::string& error) override;
};

} // namespace theia
