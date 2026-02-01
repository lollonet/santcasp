/***
    This file is part of snapcast
    Copyright (C) 2014-2025  Johannes Pohl

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
***/

#pragma once


// standard headers
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <deque>


/// Size limited queue
/**
 * Size limited queue with basic statistic functions:
 * median, mean, percentile
 */
template <class T>
class DoubleBuffer
{
public:
    /// c'tor
    explicit DoubleBuffer(size_t size = 10) : bufferSize(size)
    {
    }

    /// Add @p element, pop last, if buffer is full
    inline void add(const T& element)
    {
        buffer.push_back(element);
        if (buffer.size() > bufferSize)
            buffer.pop_front();
    }

    /// Add @p element, pop last, if buffer is full
    inline void add(T&& element)
    {
        buffer.push_back(std::move(element));
        if (buffer.size() > bufferSize)
            buffer.pop_front();
    }

    /// @return median as mean over N values around the median
    T median(size_t mean = 1) const
    {
        if (buffer.empty())
            return T{};
        std::deque<T> tmpBuffer(buffer.begin(), buffer.end());
        std::sort(tmpBuffer.begin(), tmpBuffer.end());
        if ((mean <= 1) || (tmpBuffer.size() < mean))
            return tmpBuffer[tmpBuffer.size() / 2];
        else
        {
            size_t mid = tmpBuffer.size() / 2;
            size_t low = mid - mean / 2;
            size_t high = mid + mean / 2;
            T result = T{};
            size_t count = high - low + 1;
            for (size_t i = low; i <= high; ++i)
            {
                result += tmpBuffer[i];
            }
            return result / static_cast<T>(count);
        }
    }

    /// @return mean value
    double mean() const
    {
        if (buffer.empty())
            return 0.0;
        double sum = 0.0;
        for (size_t n = 0; n < buffer.size(); ++n)
            sum += static_cast<double>(buffer[n]);
        return sum / static_cast<double>(buffer.size());
    }

    /// @return @p percentile percentile
    T percentile(unsigned int percentile) const
    {
        if (buffer.empty())
            return T{};
        std::deque<T> tmpBuffer(buffer.begin(), buffer.end());
        std::sort(tmpBuffer.begin(), tmpBuffer.end());
        return tmpBuffer[static_cast<size_t>((tmpBuffer.size() - 1) * (static_cast<double>(percentile) / 100.0))];
    }

    /// @return array of different percentiles
    template <std::size_t Size>
    std::array<T, Size> percentiles(const std::array<uint8_t, Size>& percentiles) const
    {
        std::array<T, Size> result;
        result.fill(T{});
        if (buffer.empty())
            return result;
        std::deque<T> tmpBuffer(buffer.begin(), buffer.end());
        std::sort(tmpBuffer.begin(), tmpBuffer.end());
        for (std::size_t i = 0; i < Size; ++i)
            result[i] = tmpBuffer[static_cast<size_t>((tmpBuffer.size() - 1) * (static_cast<double>(percentiles[i]) / 100.0))];

        return result;
    }

    /// @return if the buffer is full
    inline bool full() const
    {
        return (buffer.size() == bufferSize);
    }

    /// Clear the buffer
    inline void clear()
    {
        buffer.clear();
    }

    /// @return current size of the buffer
    inline size_t size() const
    {
        return buffer.size();
    }

    /// @return if the buffer is empty
    inline bool empty() const
    {
        return buffer.empty();
    }

    /// Set size of the buffer (capped at 10000)
    void setSize(size_t size)
    {
        static constexpr size_t kMaxBufferSize = 10000;
        bufferSize = std::min(size, kMaxBufferSize);
    }

    /// @return the raw buffer
    const std::deque<T>& getBuffer() const
    {
        return buffer;
    }

private:
    size_t bufferSize;
    std::deque<T> buffer;
};
